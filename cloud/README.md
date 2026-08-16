# Cloud — Elasticsearch + Kibana over HTTPS on Hetzner

Terraform provisions one Hetzner VM (SSH key, private network, a default-deny firewall
allowing only 22 and 443, cloud-init for first boot). Ansible then installs and configures
Elasticsearch, Kibana and an nginx TLS edge as native packages, all over HTTPS with an
internal CA. The only public port is 443.

## Quick start

```bash
export HCLOUD_TOKEN=<your Read & Write token>   # or let ./run.sh prompt you
cd cloud
make deploy      # preflight -> terraform -> ansible -> verify
```

Or from the repo root, `./run.sh` → **Cloud**, which walks you through the token and SSH
key interactively.

## Prerequisites

- Terraform >= 1.5, Ansible >= 2.15, Python 3, curl, openssl, ssh.
- A Hetzner Cloud account and a project.
- An SSH key pair (ed25519 recommended). `ssh-keygen -t ed25519` if you have none.

## Get a Hetzner API token

1. Open <https://console.hetzner.cloud/> and sign in.
2. Create (or open) a project.
3. Sidebar → **Security → API tokens**.
4. **Generate API token**, name it, choose **Read & Write**.
5. Copy it once and export it as `HCLOUD_TOKEN` (or save it when `run.sh` offers to).

Preflight validates the token, confirms it has write permission, checks the project is
empty, and prints the hourly rate **before** anything is created.

## Cost

The `cx33` server is roughly **EUR 0.02–0.03 per hour** including its Primary IPv4. A
deploy + test + destroy cycle costs only a few cents. **It bills until you destroy it.**

## What to expect on first access

Open the printed URL (`https://<public-ip>/`). Log in as `elastic` with the generated
password (printed at the end and stored only under `ansible/.secrets/`, gitignored). Your
browser warns about the certificate — expected: it is signed by an internal CA created at
deploy time.

## Teardown (do not skip)

```bash
cd cloud && make destroy      # or ./run.sh -> Cloud -> Destroy
```

Destroy removes the server **and its Primary IP** (billed separately, survives server
deletion), then prints a full API listing so you can see the project is empty. Always run
it when you are done — a forgotten server keeps charging.

## Layout

`terraform/` (infrastructure) · `ansible/` (configuration) · `scripts/` (preflight, deploy,
verify, destroy, logs, lint) · `Makefile` (thin wrappers).
