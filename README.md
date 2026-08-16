# Elasticsearch + Kibana over HTTPS — Automated with Terraform & Ansible

A single-node **Elasticsearch + Kibana** stack that comes up behind an **nginx TLS edge** and is reachable **only over HTTPS**. **Terraform** builds the infrastructure and **Ansible** configures the services. Deploy is one command (`./run.sh`) and teardown is one command (`./destroy.sh`) — two separate scripts, on purpose.

Two independent deployment targets are included:

- **Local** — Docker on your machine. No account, no token, no cost. This is the default, so the solution can be evaluated in about five minutes.
- **Cloud** — a Hetzner VM with a real default-deny firewall, a private network, and cloud-init for unattended first boot.

Both are complete implementations. Neither depends on the other: delete either directory and the other still deploys.

### Requirements at a glance

| Requirement | How it is met | Where |
|---|---|---|
| Terraform provisions the infrastructure | Network, volumes and containers (local); server, private network, default-deny firewall, SSH key and cloud-init (cloud). No configuration provisioners. | `local/terraform/`, `cloud/terraform/` |
| Ansible configures the services | Four roles: internal CA, Elasticsearch, Kibana, nginx. Idempotent, asserted. | `*/ansible/roles/` |
| Elasticsearch and Kibana accessible via HTTPS | nginx TLS edge; TLS on every internal hop, verified against the internal CA. Plain HTTP is refused. | `*/ansible/roles/nginx/` |
| Fully automated and reproducible | One command end to end. Versions pinned. Inventory generated from Terraform state — nothing copied by hand. | `run.sh`, `*/Makefile` |
| Replicable on your side | Two independent targets. The local one needs only Docker — no account, no token, no cost. | `run.sh` |

Elasticsearch and Kibana are pinned to **8.15.3**.

---

## 1. Quick Start (How to Run)

You do not need to read the rest of this document to try it. Two commands bring the entire stack up.

### The fastest path

From the repository root:

```bash
./run.sh
```

`./run.sh` is an interactive launcher. It greets you, lets you pick **Local** (Docker on this machine — the default) or **Cloud** (a Hetzner VM), then runs everything for you: environment checks, deploy, and credentials. Press Enter to accept the defaults and you are done. Teardown is intentionally kept out of this script — see [Tear it down](#tear-it-down) below.

### The direct path (Local)

If you prefer to run the steps yourself, the local target is completely self-contained:

```bash
cd local
ansible-galaxy collection install -r ansible/requirements.yml   # first run only
make deploy
```

`make deploy` does the full sequence on its own — it validates your machine, provisions the infrastructure with Terraform, configures the services with Ansible, and runs the test suite at the end. The first run takes about three to six minutes (image download and first boot); later runs take under two minutes.

When it finishes you will see the access details:

```
URL:      https://localhost:8443/
Username: elastic
Password: <generated at deploy time>
```

Open the URL and log in.

> **About the certificate.** The stack generates its own certificate authority at deploy time and issues certificates from it, so TLS is real end to end — on the public edge and on every internal hop, each one validated against that CA. Because the CA is created locally and is not in your browser's trust store, the browser shows a warning on first visit. This is the expected behaviour of a self-contained deployment with no registered domain: a trust-chain notice, not a transport-security problem.
>
> Remove it, or side-step it entirely:
>
> ```bash
> # Trust the generated CA (recommended for review) — Debian/Ubuntu:
> sudo cp local/ansible/.certs/ca.crt /usr/local/share/ca-certificates/elk-ca.crt \
>   && sudo update-ca-certificates
> # macOS:
> sudo security add-trusted-cert -d -r trustRoot \
>   -k /Library/Keychains/System.keychain local/ansible/.certs/ca.crt
>
> # Or verify from the command line, no trust store touched, no browser warning:
> curl --cacert local/ansible/.certs/ca.crt https://localhost:8443/api/status
> ```
>
> For an internet-facing deployment with a real domain, switching to ACME (Let's Encrypt) is a change in the `ca`/`nginx` roles rather than a rewrite — there is no ACME toggle in the code today. The internal CA is the default precisely because it needs no domain and no internet access, and keeps the trust model identical across both targets (on `localhost`, ACME cannot issue a certificate at all).

### Everyday commands

Every step is also available on its own, so a reviewer can inspect one thing at a time:

| Command | What it does |
|---------|--------------|
| `make preflight` | Check the environment only — no deployment. Fails fast and prints the exact fix for any missing prerequisite. |
| `make deploy` | Full deploy: preflight → Terraform → Ansible → verify. |
| `make verify` | Run the functional and security checks against a running stack. |
| `make idempotency` | Run Ansible twice and assert the second run reports `changed=0`. |
| `make logs` | Tail recent logs from the three services. |
| `make destroy` | Remove the containers, network, and volumes. |
| `make reset` | Destroy **and** purge generated certs, secrets, and inventory for a true cold start. |

> **Prerequisites (Local):** Docker Engine 20.10+, Terraform 1.5+ (OpenTofu also works), `ansible-core` 2.15+, Python 3 with the `docker` SDK, plus `make`, `curl`, and `openssl`. You do not need to check these by hand — `make preflight` runs 27 checks on the local target and tells you precisely what to fix. It also runs automatically inside `make deploy`.

### Deploying to the cloud target (Hetzner)

The same stack also deploys to a Hetzner VM, on real public infrastructure:

```bash
export HCLOUD_TOKEN=<your Read & Write token>   # or let ./run.sh prompt you
cd cloud
make deploy
```

Here the only public port is `443`, behind a default-deny firewall. The cloud preflight runs 19 checks: it validates the token, confirms it has write permission, checks the project is empty, and prints the hourly rate **before** anything is created. Remember to tear it down when you are done, as a live server keeps billing.

### Tear it down

Teardown is a separate, deliberate action — it is **not** hidden inside `./run.sh`, so a running stack is never removed by accident. Use the dedicated launcher:

```bash
./destroy.sh
```

`./destroy.sh` mirrors `./run.sh`: it shows what is currently deployed, lets you pick **Local** or **Cloud**, confirms, and then tears that target down. For the local target it removes the containers, network, and volumes; for the cloud target it destroys the Hetzner server and everything Terraform created (the server's public IP is auto-assigned and goes with it), then prints a project-scoped listing (everything labelled `project==elk-cloud`) so you can see this deployment is fully gone — anything you keep in the account yourself is left untouched. It can also run non-interactively:

```bash
./destroy.sh --target local  --yes             # remove the local stack
./destroy.sh --target cloud  --yes             # remove the Hetzner server and prove the project is empty
./destroy.sh --target local  --purge --yes     # also wipe generated certs/secrets/state (a true cold start)
```

The manual path per target works the same way (`make destroy`, or `make reset` to also purge generated certs/secrets/inventory), under both `local/` and `cloud/`.

---

## 2. Architecture & Features

The design rests on one clean idea: **Terraform decides what exists, and Ansible decides how it is configured.** The only thing that passes between the two layers is a machine-generated inventory. That boundary keeps each layer small and testable, and it is what makes the same solution portable from Docker to any cloud provider.

### The request path

```
                 client (browser / curl)
                          |
                    HTTPS only  (:8443 local  /  :443 cloud)   <- the one open port
                          |
                    +-----v------+
                    |   nginx    |   TLS termination + reverse proxy
                    +--+------+--+
                 "/" |      | "/es/"
                     v      v
             +-------+--+  +-+---------------+
             |  Kibana  |  |  Elasticsearch  |   bound to loopback,
             +----------+  +-----------------+   no externally reachable port
                  every internal hop is HTTPS, verified against the internal CA
```

Kibana is served at `/` and the Elasticsearch API at `/es/`. Elasticsearch and Kibana have no port that can be reached from outside — the only way in is through the TLS edge.

### Terraform provisions the infrastructure

Terraform owns everything that "exists." On the local target it creates a private Docker network on an uncommon subnet (`172.31.240.0/24`, to dodge home/VPN/corporate range collisions), named volumes, and the three service containers. On the cloud target it creates the Hetzner server, a private network and subnet, a default-deny firewall that allows only inbound 22 and 443 (plus ICMP echo), an SSH key, and cloud-init for unattended first boot; the server's public IP is auto-assigned. In both cases Terraform's final act is to write out the inventory that Ansible consumes. There are no configuration provisioners hidden inside Terraform — configuration is entirely Ansible's job, which keeps the two concerns from tangling.

### Ansible configures and provisions the services

Ansible takes the inventory and does all of the real setup through four focused roles. The `ca` role generates an internal certificate authority and issues TLS certificates for each service. The `elasticsearch`, `kibana`, and `nginx` roles install version-pinned software, render configuration from templates, wire in the certificates, enable security, and set generated passwords. The playbooks are idempotent by design — a second run reports `changed=0`, and `make idempotency` asserts exactly that rather than assuming it.

### Reproducible, and structured to replicate

A single `make deploy` performs the entire pipeline end to end, and the inventory that links Terraform to Ansible is generated from state, so no address, container name or IP is ever copied by hand. Versions are pinned — Elasticsearch and Kibana `8.15.3`, the nginx image `nginxinc/nginx-unprivileged:1.27.2-alpine`, no `latest` tags — and the Terraform providers and Ansible collections are version-constrained. The `local/` and `cloud/` trees are each self-contained: neither references the other (a cross-tree grep finds nothing), and `run.sh`/`destroy.sh` only orchestrate by shelling into whichever one you pick, so deleting either directory leaves the other fully deployable. Because the default path runs entirely on Docker, a reviewer can clone the repository and get a passing deployment with no account, no API token and no cost.

### Repository layout

```
.
├── run.sh              # deploy launcher — interactive or non-interactive (local or cloud)
├── destroy.sh          # teardown launcher — separate from run.sh, on purpose
├── local/              # self-contained Local (Docker) target
│   ├── terraform/      # network, volumes, containers  (what exists)
│   ├── ansible/        # roles: ca, elasticsearch, kibana, nginx  (how it is set up)
│   ├── scripts/        # preflight, deploy, verify, destroy, lint
│   └── Makefile        # thin wrappers over the scripts
├── cloud/              # self-contained Cloud (Hetzner) target — same shape
├── README.md           # this file
└── TESTING.md          # captured test output and coverage notes
```

---

## 3. Security posture

### Enforced, and proven by the test suite

| Control | Detail |
|---|---|
| Authentication | `xpack.security.enabled: true`. Anonymous access is rejected — `verify.sh` asserts a 401/403 rather than assuming it. |
| Encryption in transit | TLS at the edge **and** on every internal hop (nginx→Elasticsearch and nginx→Kibana both use `proxy_ssl_verify on` against the internal CA). Plain HTTP is refused, not silently downgraded. |
| Attack surface | Exactly one exposed port. Elasticsearch and Kibana bind to loopback / the private network and are demonstrably unreachable from outside — the test suite scans the ports and proves this rather than claiming it. |
| Network boundary (cloud) | Default-deny inbound firewall; only 22 and 443 open (plus ICMP echo). Verified by scanning the public IP after deploy. |
| Host hardening (cloud) | Root SSH login disabled, password authentication disabled, key-only access, non-root admin user — all applied by cloud-init at first boot, before configuration management connects. |
| Container hardening (local) | Non-root users, all Linux capabilities dropped (`drop = ["ALL"]`), `no-new-privileges`, and a read-only root filesystem on nginx (with minimal tmpfs mounts). |
| Secrets | Generated at deploy time, never committed. They exist only under ignored paths and are printed once. |
| Supply chain | Elasticsearch, Kibana and the nginx image are pinned; providers and collections are version-constrained. No `latest` tags. |

### Not production-grade, and what I would change

Being explicit about this matters more than claiming completeness:

- **Self-signed internal CA — deliberate,** so the deployment is self-contained and needs no domain or internet access. TLS is real on every hop; only the trust anchor is local. For internet-facing use with a real domain, switch to ACME (Let's Encrypt) or a managed CA.
- **Single node.** Cluster health is `yellow` because replicas cannot be placed — expected, not a fault. Production needs at least three nodes with dedicated roles.
- **Secrets printed to the terminal.** Acceptable for a demo; production needs Vault or a cloud secrets manager with rotation and audit.
- **No snapshots, no audit logging.** Both are required before this holds data that matters.
- **No rate limiting or WAF at the edge.** Needed if exposed to the internet.
- **Firewall source CIDR defaults to open** (`0.0.0.0/0`, `::/0`) so a reviewer can reproduce without editing. In real use `allowed_ssh_cidrs` / `allowed_https_cidrs` should be narrowed to a known range.
- **Read-only rootfs and memory locking** are not applied to Elasticsearch/Kibana in the local target; documented trade-offs for a "runs anywhere" demo.

---

## 4. Portability

Only the Terraform layer changes between environments. The Ansible layer targets an inventory, not a provider, so it stays the same — this repository already demonstrates that across two very different targets (Docker and Hetzner).

| This repo | AWS | GCP | Azure |
|---|---|---|---|
| `hcloud_network` / `docker_network` | VPC + subnet | VPC + subnetwork | VNet + subnet |
| `hcloud_server` / `docker_container` | EC2 | Compute Engine | Linux VM |
| `hcloud_firewall` | Security Group | Firewall rules | Network Security Group |
| cloud-init `user_data` | `user_data` | `metadata.startup-script` | `custom_data` |
| server public IP (`public_net`) | Elastic IP | Static external IP | Public IP |
| internal CA (Ansible) | ACM Private CA | CA Service | Key Vault certificate |
| generated inventory | `aws_ec2` dynamic inventory | `gcp_compute` inventory | `azure_rm` inventory |

Moving to a hyperscaler means rewriting `terraform/` and leaving `ansible/` untouched. On a managed cloud I would additionally use the provider's secrets service with a workload identity — Key Vault with a managed identity on Azure, or Secrets Manager with an instance role on AWS — so no static credential exists at all.

---

## 5. Design decisions and testing

### Tooling and ownership

I use AI assistants in my daily engineering work and did so here. The division was deliberate: the architecture, the layer boundaries between Terraform and Ansible, the security posture, and every design decision documented above are mine. I used the tooling to accelerate implementation and to run the repetitive edit-test-fix loop, using a stronger model for structural reasoning and a faster one for iteration.

Every failure encountered during testing was diagnosed against my own understanding of the stack rather than by accepting a generated patch. Every choice in this repository is one I can defend and would make again.

### Key decisions

Each row is a decision I made on purpose, the reason for it, and the alternative I rejected.

| Decision | Why | Alternative I rejected |
|---|---|---|
| Terraform provisions; Ansible does **all** configuration | Two small, testable layers. The Ansible layer is portable because it targets an inventory, not a provider — the same roles run against Docker and Hetzner unchanged. | Configuration inside Terraform via `local-exec`/provisioners — not idempotent, mixes concerns. There are no provisioners in this repo. |
| cloud-init does first-boot bootstrap only | cloud-init runs once and is not idempotent, and the task asks for Ansible to own configuration. So it is limited to the minimum a fresh box needs (admin user, SSH hardening, `vm.max_map_count`, python3) and a completion marker. | Putting service config in cloud-init — unrepeatable, and it drifts the moment anything changes. |
| Ordering is gated on real readiness, never timed | Ansible waits for SSH, then for cloud-init (`cloud-init status --wait` **and** a completion-marker file), and each role clears a real health gate — Elasticsearch genuinely green/yellow, Kibana genuinely "available" — before the next starts. "Started" is not "ready". | Fixed `sleep`s — flaky: either too short (races) or too slow (wasted minutes), and they hide real failures. |
| Internal CA, not Let's Encrypt | Works with no domain and no outbound internet, and keeps the trust model identical on both targets — on `localhost` an ACME certificate cannot be issued at all. TLS is real on every hop; only the trust anchor is local. | ACME — needs a public domain and outbound internet during deploy, and would give the local and cloud paths different TLS stories. Right choice once a real domain exists. |
| Exactly one exposed port; backends on loopback / the private network | Smallest possible attack surface. `verify.sh` scans 9200/5601 and proves they are unreachable from outside rather than assuming it. | Publishing 9200/5601 "for debugging" — `docker logs`/`exec` and the `/es/` proxy already cover that, without opening a port. |
| Two independent trees, not one parametrised codebase | A change to one target cannot break the other, and either can be handed over or deleted on its own (a cross-tree grep finds no coupling). | One shared codebase with `if local/cloud` conditionals — cross-coupling that is hard to reason about and easy to break. |
| Single node | Right-sized for the task; `yellow` health is expected because replicas cannot be placed. Scaling out is an inventory + settings change, not a rewrite, because the roles are inventory-driven. | A multi-node cluster — more memory and moving parts than the challenge needs. |
| Local hardening: drop all capabilities, `no-new-privileges`, read-only rootfs on nginx | Minimise what a compromised container can do; nginx runs as a non-root image so a read-only rootfs (with small tmpfs mounts) is clean. | A read-only rootfs on Elasticsearch/Kibana too — needs several brittle tmpfs mounts; documented as a local-demo trade-off rather than done badly. |
| Sentinel handshake (local): the container blocks until Ansible has placed its config, then starts | Lets Ansible own every byte of configuration before first boot, race-free, while Terraform still owns the container lifecycle. | Letting Ansible create/start the containers — fights Terraform's ownership of "what exists". |

### Testing

Both targets were deployed from a clean state and verified end to end. Captured output is in `TESTING.md`.

**Local:** repeated cold deploys from an empty state, full functional and security verification (10/10 in `verify.sh`), an idempotency assertion (a second Ansible run must report `changed=0`), and clean teardown.

**Cloud:** run against a real Hetzner project. This iteration surfaced and fixed genuine environment-specific issues before the final run completed with all 14 checks green — most notably:

- The custom `elasticsearch.yml` replaces the packaged config, which dropped the deb's default `path.data`/`path.logs`; Elasticsearch then fell back to a directory under `/usr/share/elasticsearch` that the service user cannot create and died during logging init, before writing a single line. Fixed by pinning both paths to the package-owned directories.
- Ubuntu 24.04 ships nginx 1.24, where the newer `http2 on;` directive does not exist; enabling HTTP/2 on the `listen` line instead makes the vhost valid. The nginx config is now validated with a full `nginx -t` after rendering.

**Failure paths** are tested without provisioning anything — that is the point of preflight: an invalid token, a read-only token, a missing or wrong-permission SSH key, and a non-empty project are all caught before a single billable API call.

---

## 6. Troubleshooting

`make preflight` usually names the exact problem and its fix. Beyond that:

| Symptom | Cause | Fix |
|---|---|---|
| Elasticsearch restarts; log mentions `max_map_count` | Kernel setting too low | Linux: `sudo sysctl -w vm.max_map_count=262144`. Docker Desktop: usually preset. WSL2: set it in the distro, then `wsl --shutdown`. |
| Port already in use | 8443 taken by another process | Set `published_https_port` in `local/terraform/terraform.tfvars`. |
| Ansible module not found | Collections not installed | `ansible-galaxy collection install -r ansible/requirements.yml` |
| `docker` SDK import error | SDK installed in a different Python than Ansible uses | Preflight prints the exact interpreter path and command. |
| Kibana stuck at "server is not ready" | Elasticsearch not yet healthy, or the kibana_system credential is wrong | Wait for the health gate; then check `make logs`. The deploy gates are designed to prevent this. |
| Cluster health is `yellow` | Single node cannot place replicas | Expected. Not a fault. |
| Cloud: SSH host key mismatch | A previous server reused the public IP | The deploy purges the stale `known_hosts` entry automatically; if run by hand, remove it and retry. |

---

## 7. Future Improvements

The current solution is intentionally right-sized for the challenge. The natural next steps toward a production-grade platform:

1. **Multi-node clustering and high availability.** A three-node Elasticsearch cluster with dedicated master/data roles and replica shards, so the stack survives the loss of any one node. Largely an inventory and settings change, since the roles are inventory-driven.
2. **CI/CD pipeline integration.** Wire the existing lint, preflight, deploy, verify, and idempotency gates into a pipeline (for example GitHub Actions) that runs the full suite on every push.
3. **External secrets management.** Replace the deploy-time generated secrets with **HashiCorp Vault** or a cloud secrets manager, for centralized rotation, auditing, and access control.
4. **Publicly trusted certificates via ACME.** For an internet-facing deployment with a real domain, swap the internal CA for automatically issued and renewed **Let's Encrypt** certificates, keeping HTTPS end to end.
5. **Backups, monitoring, and observability.** Automated snapshot/restore for Elasticsearch, audit logging, and shipping metrics and logs to a monitoring stack with alerting.

---

*To deploy, start with `./run.sh` (or `cd local && make deploy`); to tear down, use `./destroy.sh`. See `TESTING.md` for how it was tested.*
