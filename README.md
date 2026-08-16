# Elasticsearch + Kibana over HTTPS — Terraform builds it, Ansible configures it

## Quick start

```bash
git clone <repo> && cd <repo>
./run.sh
```

`./run.sh` asks whether to deploy **Local** (Docker on this machine) or **Cloud**
(a Hetzner VM), then walks you through the rest — preflight, deploy, credentials,
and teardown.

## What this deploys

A single-node **Elasticsearch + Kibana** stack behind an **nginx TLS edge**, reachable
only over **HTTPS**. **Terraform** provisions the infrastructure; **Ansible** configures
the services (internal CA, TLS on every hop, security enabled, health-gated startup).
The only thing passed between the two layers is a machine-generated inventory.

## The two targets

| Target | Needs | Cost | Time |
|--------|-------|------|------|
| Local | Docker + Terraform + Ansible | Free | ~5 min (first run) |
| Cloud | Hetzner account + API token + SSH key | ~EUR 0.03/hour | ~5–8 min |

Each side is a **self-contained project**: `cd local && make deploy` and
`cd cloud && make deploy` both work without the launcher, and either works if the
other directory is deleted.

## Prerequisites

| Tool | Minimum | Notes |
|------|---------|-------|
| Terraform | 1.5 | OpenTofu works too |
| Ansible (`ansible-core`) | 2.15 | `pipx install ansible-core` |
| Python 3 | 3.9 | Local also needs the `docker` SDK |
| curl, openssl | any | used by preflight and verify |
| Docker Engine | 20.10 | **Local only** |
| SSH client + key | any | **Cloud only** (ed25519 recommended) |

## Architecture

```
                 client (browser / curl)
                          |
                    HTTPS (:443 cloud / :8443 local)   <- the only open port
                          |
                    +-----v------+
                    |   nginx    |  TLS termination + reverse proxy
                    +--+------+--+
                 "/" |      | "/es/"
                     v      v
             +-------+--+  +-+---------------+
             |  Kibana  |  |  Elasticsearch  |   bound to loopback,
             +----------+  +-----------------+   no external port
                  every hop is HTTPS, verifying the internal CA
```

## How each mandatory requirement is met

| Requirement | Where |
|-------------|-------|
| Terraform provisions infrastructure | `local/terraform/` (Docker), `cloud/terraform/` (Hetzner) |
| Ansible configures the services | `local/ansible/`, `cloud/ansible/` (roles: ca, elasticsearch, kibana, nginx) |
| HTTPS everywhere | nginx edge + TLS on ES/Kibana + internal CA (`roles/ca`, `*.yml.j2`) |
| Reproducible & automated | pinned versions, `make deploy`, generated inventory, idempotent playbooks |
| One repository | this repo; `./run.sh` is the single entry point |

## Design decisions

| Decision | Why |
|----------|-----|
| Terraform = infra only, Ansible = config only | Small, testable layers; the Ansible layer is portable to any host |
| Internal CA (not Let's Encrypt) | No public domain; works offline and for a raw IP |
| One exposed port | Smallest attack surface; backends are unreachable from outside |
| Single node | Right-sized for the task; `yellow` health is expected (no replicas) |
| cloud-init limited to first boot | Unattended bootstrap only; all real config is Ansible's job |
| Pinned versions | Same code resolves the same way on every machine |

## Security

**Hardened:** authentication enforced (verify proves an anonymous request is rejected);
HTTPS on the edge and every internal hop against the internal CA; exactly one open port;
backends bound to loopback and proven unreachable; systemd/container hardening; no secrets
in Git (generated passwords/keys live only under gitignored paths).

**Not production-grade:** self-signed internal CA (use ACME/an internal PKI with a real
domain); single node with no snapshots/backups or audit logging; passwords printed once to
the terminal (use a secrets manager); no WAF/rate limiting at the edge.

## Cloud mapping

The Ansible layer is provider-agnostic (it targets an inventory); only Terraform changes.

| This repo (Hetzner) | AWS | GCP | Azure |
|---------------------|-----|-----|-------|
| `hcloud_server` | EC2 | Compute Engine | VM |
| `hcloud_network` / `_subnet` | VPC + subnet | VPC + subnetwork | VNet + subnet |
| `hcloud_firewall` (22/443) | Security Group | Firewall rules | NSG |
| `hcloud_ssh_key` | Key Pair | OS Login / metadata key | SSH public key |
| cloud-init `user_data` | EC2 user data | startup-script | customData |
| `local_file` inventory | `aws_ec2` dynamic inventory | `gcp_compute` inventory | `azure_rm` inventory |

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Kibana shows "server is not ready" | ES/Kibana credential or TLS trust issue — re-run deploy; check `make logs`. Never mask with a longer wait. |
| Local: ES restarts, `max_map_count` too low | `sudo sysctl -w vm.max_map_count=262144` |
| Cloud: SSH hangs | passphrase key without a loaded agent — `ssh-add`, then re-run (preflight warns about this) |
| Cloud: still billing | run `./run.sh` → Cloud → Destroy; it proves the project is empty |
| Cluster health is `yellow` | expected on a single node (no replicas) |

## More

- Local details: [local/README.md](local/README.md)
- Cloud details: [cloud/README.md](cloud/README.md)
- Test evidence: [TESTING.md](TESTING.md)
