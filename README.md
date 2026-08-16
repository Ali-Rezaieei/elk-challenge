# Local HTTPS Elasticsearch + Kibana — Terraform builds it, Ansible configures it

A single-node **Elasticsearch + Kibana** stack that runs on your own machine and is
reachable only over **HTTPS**, behind an **nginx** reverse proxy. **Terraform** creates
the infrastructure (network, volumes, containers). **Ansible** does all configuration
(TLS certificates, service config, passwords, health checks). One `git clone` and one
`make deploy` — no cloud account, no API keys.

The key idea is a clean split: **Terraform decides what exists; Ansible decides how it
is set up.** The only thing passed between them is a machine-generated inventory. That
boundary is what makes the same design portable to any cloud (see [section 8](#8-mapping-to-a-cloud-provider)).

---

## 1. What you get

- A private Docker network on an uncommon subnet (avoids VPN/home clashes).
- **Elasticsearch 8.15.3** and **Kibana 8.15.3** (same version, as Elastic requires).
- An **nginx** TLS edge that serves Kibana at `/` and the Elasticsearch API at `/es/`.
- Exactly **one** open port: `127.0.0.1:8443`. Elasticsearch and Kibana have no open
  ports and cannot be reached from the host.

---

## 2. Architecture

```
                        host machine
                             |
                   127.0.0.1:8443  (HTTPS — the only open port)
                             |
                    +--------v---------+
                    |      nginx       |  TLS termination + reverse proxy
                    | non-root, caps   |  read-only rootfs
                    |   dropped        |
                    +----+--------+----+
                "/"      |        |   "/es/"
                         v        v
              +----------+--+  +--+-----------------+
              |   Kibana    |  |  Elasticsearch     |
              |  (TLS, no   |  |  (TLS, no open     |
              |  open port) |  |   port)            |
              +-------------+  +--------------------+
                    private docker network only
                 (every hop verifies the internal CA)
```

Every arrow is HTTPS.

---

## 3. Prerequisites

| Tool | Minimum | Note |
|------|---------|------|
| Docker Engine / Desktop | 20.10 | Running, and usable without `sudo`. |
| Terraform | 1.5 | OpenTofu also works. |
| Ansible (`ansible-core`) | 2.15 | e.g. `pipx install ansible-core`. |
| Python 3 + `docker` SDK | 3.9 | The SDK must be importable by the Python that Ansible uses. |
| `make`, `curl`, `openssl` | any | `jq` is optional. |
| RAM for Docker | ~3 GB | On macOS/Windows this is the Docker Desktop VM, not host RAM. |
| `vm.max_map_count` | 262144 | Kernel setting Elasticsearch needs (see [section 9](#9-troubleshooting)). |

You do not need to check these by hand. `make preflight` runs 23 checks and prints the
exact fix for your OS on any failure. It runs automatically inside `make deploy`.

---

## 4. Quick start

Make sure Docker is running, then run these in order from the project folder.

**Step 1 — Install the dependencies (only the first time):**

```bash
ansible-galaxy collection install -r ansible/requirements.yml
```

**Step 2 — Bring the stack up:**

```bash
make deploy
```

This one command does everything: it checks your machine, builds the
infrastructure with Terraform, configures the services with Ansible, and runs the
tests. First run takes ~3–6 minutes (image download + first boot); later runs
~60–90 seconds. When it finishes you will see:

```
== Verify ==
  [PASS] HTTPS edge responds and TLS validates against the internal CA
  [PASS] Plain HTTP is refused
  [PASS] Elasticsearch cluster health is green/yellow
  [PASS] Kibana status is 'available'
  [PASS] Unauthenticated request is rejected (security is ON)
  [PASS] Authenticated request succeeds
  [PASS] Elasticsearch:9200 and Kibana:5601 are NOT reachable from the host
  [PASS] Edge certificate is valid and covers 'localhost'
  PASS=8  FAIL=0

  URL:      https://localhost:8443/
  Username: elastic
  Password: <generated at deploy time>
```

**Step 3 — Open it:** go to <https://localhost:8443/> and log in as `elastic` with
the password shown above (a browser certificate warning is expected — see
[section 5](#5-first-time-you-open-it)).

**Step 4 — Bring the stack down when you are done:**

```bash
make destroy   # remove the containers, network, and volumes
# or, for a completely clean slate (also deletes generated certs/secrets):
make reset
```

**Other commands (optional):**

| Command | What it does |
|---------|--------------|
| `make verify` | Re-run the functional + security checks on a running stack. |
| `make idempotency` | Run Ansible twice; the second run must report `changed=0`. |
| `make lint` | `terraform fmt`/`validate`, `ansible-lint`, `shellcheck`, `yamllint`. |
| `make preflight` | Just check the environment, without deploying. |

---

## 5. First time you open it

- **A browser certificate warning is expected.** The certificate is signed by an
  internal CA that is created on your machine at deploy time — there is no public
  domain and no external CA. Click through, or trust `ansible/.certs/ca.crt` to remove
  the warning.
- **Credentials.** The `elastic` password is generated at deploy time, saved only in
  `ansible/.secrets/elastic_password` (gitignored), and printed once at the end.

---

## 6. Design decisions

Each row is: **decision → why → what I rejected.**

| Decision | Why | Rejected |
|----------|-----|----------|
| Docker as the local provider | Runs on any machine, free, no cloud account | Real cloud (needs credentials/cost); local Kubernetes (too heavy for 3 containers) |
| Terraform = infrastructure only; Ansible = configuration only | Each layer stays small, testable, and the Ansible part is reusable on any host | Doing config in Terraform via `local-exec` (not idempotent; mixes concerns) — there are **no** provisioners |
| No `docker-compose.yml` | Compose would replace both tools and fail the brief | Adding one "for convenience" |
| A "sentinel" handshake: the container waits until Ansible finishes, then starts | Lets Ansible own all config before first boot, race-free | Letting Ansible manage the container lifecycle (fights Terraform's ownership) |
| Internal CA, not Let's Encrypt | `localhost` has no public domain and may be offline | Let's Encrypt (cannot issue for localhost); a committed certificate (secret in Git) |
| One open port, bound to `127.0.0.1` | Smallest possible attack surface; not even reachable on the LAN | Publishing 9200/5601 "for debugging" (`docker logs`/`exec` cover that) |
| Single node | Small and simple for a demo; `yellow` health is normal (no replicas) | A multi-node cluster (more memory and moving parts than the task needs) |
| Pinned versions (ES/Kibana 8.15.3, provider, collections) | Same code resolves the same way on every machine | `latest` tags (break reproducibility) |

**Scaling out:** add more container resources (or cloud instances), remove
`discovery.type: single-node`, set the discovery/seed settings, and raise replicas. The
Ansible roles do not change, because they target an inventory.

---

## 7. Security

**Hardened**

- Authentication is on and enforced; `verify.sh` *proves* it (an anonymous request is
  rejected).
- HTTPS on the edge **and** on every internal hop, each verifying the internal CA.
- One open port, on loopback only. Backends are unreachable from the host (proven).
- Containers run non-root with **all Linux capabilities dropped** and
  `no-new-privileges`. nginx also has a **read-only root filesystem**.
- No secrets in Git: passwords/keys live only under gitignored paths and are printed
  once.

**Not production-grade (and what I would change)**

- Self-signed local CA → use ACME with a real domain or an internal CA.
- ES/Kibana are not read-only rootfs, and memory is not locked → tune for production.
- Single node, no backups/snapshots, no audit logging → add for production.
- Passwords are printed to the terminal → push to a secrets manager (Vault, SSM).
- No rate limiting or WAF at the edge → add if internet-facing.

---

## 8. Mapping to a cloud provider

Only the **Terraform** layer changes between providers. The **Ansible** layer stays the
same, because it targets an inventory, not a provider.

| This repo (Docker) | AWS | GCP | Azure |
|--------------------|-----|-----|-------|
| `docker_network` | VPC + subnets | VPC + subnetwork | VNet + subnet |
| `docker_container` (ES/Kibana) | EC2 / ECS task | Compute Engine / GKE | VM / Container Instance |
| `docker_container` (nginx) | ALB or nginx on EC2 | HTTPS LB or nginx on GCE | App Gateway or nginx on VM |
| `ports { 127.0.0.1:8443 }` | Security group + listener | Firewall + forwarding rule | NSG + LB rule |
| `docker_volume` | EBS | Persistent Disk | Managed Disk |
| internal CA (Ansible) | ACM Private CA | CA Service | Key Vault cert |
| generated inventory | `aws_ec2` dynamic inventory | `gcp_compute` inventory | `azure_rm` inventory |

---

## 9. Troubleshooting

Run `make preflight` first — it usually names the exact problem and fix.

| Symptom | Cause | Fix |
|---------|-------|-----|
| Elasticsearch keeps restarting; log says `max_map_count` too low | Kernel setting too low | Linux: `sudo sysctl -w vm.max_map_count=262144`. Docker Desktop: usually preset. WSL2: set it in the distro and `wsl --shutdown`. |
| `make deploy` stops: port in use | 8443 is taken | Set `published_https_port` in `terraform/terraform.tfvars`. |
| Ansible error about a missing module | Collections not installed | `ansible-galaxy collection install -r ansible/requirements.yml`. |
| `docker` SDK import error | SDK in a different Python than Ansible uses | `"$(which python3)" -m pip install docker` (preflight prints the exact path). |
| Kibana never becomes "available" | Still starting, or ES is unhealthy | Wait, then check `docker logs <prefix>-kibana` / `-elasticsearch`. |
| Cluster health is **yellow** | Single node cannot place replicas | Expected, not a fault. |

---

## 10. Known limitations & next steps

- Changes to Elasticsearch/Kibana config need `make reset && make deploy` (nginx
  reloads live). The design favours correct first runs and no-op re-runs.
- Health/API calls assume `curl` exists in the Elastic images (it does in 8.x).
- Read-only rootfs is applied to nginx only.
- With more time: a snapshot/restore role, audit logging, a multi-node profile, and CI
  that runs the full test gate on every push.

---

**Layout:** `terraform/` (infrastructure) · `ansible/` (configuration) · `scripts/`
(preflight, deploy, verify, destroy, lint). See `TESTING.md` for how it was tested.
