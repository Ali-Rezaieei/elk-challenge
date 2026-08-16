# Elasticsearch + Kibana over HTTPS — Automated with Terraform & Ansible

A single-node **Elasticsearch + Kibana** stack that comes up behind an **nginx TLS edge** and is reachable **only over HTTPS**. **Terraform** builds the infrastructure and **Ansible** configures the services. Deploy is one command (`./run.sh`) and teardown is one command (`./destroy.sh`) — two separate scripts, on purpose — and the whole thing runs on your own machine with no cloud account required.

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

Open the URL, accept the certificate warning (the certificate is signed by a CA created on your machine, so this is expected), and log in.

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

> **Prerequisites (Local):** Docker Engine 20.10+, Terraform 1.5+ (OpenTofu also works), `ansible-core` 2.15+, Python 3 with the `docker` SDK, plus `make`, `curl`, and `openssl`. You do not need to check these by hand — `make preflight` runs a full battery of checks and tells you precisely what to fix. It also runs automatically inside `make deploy`.

### Running against a real cloud (optional)

The same stack also deploys to a Hetzner VM if you want to see it on public infrastructure:

```bash
export HCLOUD_TOKEN=<your Read & Write token>   # or let ./run.sh prompt you
cd cloud
make deploy
```

Here the only public port is `443`, protected by a default-deny firewall. Preflight validates the token, confirms it has write permission, checks the project is empty, and prints the hourly rate **before** anything is created. Remember to tear it down when you are done, as a live server keeps billing.

### Tear it down

Teardown is a separate, deliberate action — it is **not** hidden inside `./run.sh`, so a running stack is never removed by accident. Use the dedicated launcher:

```bash
./destroy.sh
```

`./destroy.sh` mirrors `./run.sh`: it shows what is currently deployed, lets you pick **Local** or **Cloud**, confirms, and then tears that target down. For the local target it removes the containers, network, and volumes; for the cloud target it deletes the Hetzner server **and** its Primary IP (billed separately), then prints a full project listing so you can see nothing is left billing. It can also run non-interactively:

```bash
./destroy.sh --target local  --yes             # remove the local stack
./destroy.sh --target cloud  --yes             # remove the Hetzner server and prove the project is empty
./destroy.sh --target local  --purge --yes     # also wipe generated certs/secrets/state (a true cold start)
```

The manual path per target works exactly the same way:

```bash
cd local && make destroy     # remove the containers, network, and volumes
cd local && make reset       # destroy AND purge generated certs/secrets/inventory
```

The same `make destroy` and `make reset` targets exist under `cloud/`.

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

Terraform owns everything that "exists." On the local target it creates a private Docker network on an uncommon subnet, named volumes, and the three service containers. On the cloud target it creates the Hetzner server, a private network and subnet, a default-deny firewall that allows only ports 22 and 443, an SSH key, and a Primary IP, and it uses cloud-init purely for unattended first boot. In both cases Terraform's final act is to write out the inventory that Ansible consumes. There are no configuration provisioners hidden inside Terraform — configuration is entirely Ansible's job, which keeps the two concerns from tangling.

### Ansible configures and provisions the services

Ansible takes the inventory and does all of the real setup through four focused roles. The `ca` role generates an internal certificate authority and issues TLS certificates for each service. The `elasticsearch`, `kibana`, and `nginx` roles install version-pinned software, render configuration from templates, wire in the certificates, enable security, and set generated passwords. The playbooks are idempotent by design, so re-running them is safe and makes no unnecessary changes.

### Elasticsearch and Kibana are securely accessible via HTTPS

Security is not an afterthought here; it is the default posture. TLS is present on the public edge **and** on every internal hop, each one validated against the internal CA. Authentication is enabled and enforced — the test suite proves this by confirming that an anonymous request is rejected and an authenticated one succeeds. Plain HTTP is refused rather than silently downgraded. Exactly one port is exposed, the backends are bound to loopback and are demonstrably unreachable from the host, and generated passwords and keys never enter version control — they live only under ignored paths and are printed once at the end of a deploy.

### The whole process is automated, reproducible, and easy to replicate

Reproducibility is built in rather than hoped for. Every version is pinned — Elasticsearch and Kibana 8.15.3, the Terraform providers, and the Ansible collections — so the same code resolves the same way on every machine. A single `make deploy` performs the entire pipeline end to end, the inventory that links Terraform to Ansible is generated automatically, and idempotency is not just claimed but asserted: a second Ansible run must report `changed=0`. The repository is deliberately structured so your team can replicate it with no friction. The `local/` and `cloud/` trees are each self-contained — either works if the other directory is deleted, and neither references the other — and `./run.sh` is the single, obvious entry point. Because the recommended path runs entirely on Docker, a reviewer can clone the repository and get a passing deployment without an account, an API token, or any special setup. Captured test evidence lives in `TESTING.md`.

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
└── TESTING.md          # captured test output and honest coverage notes
```

---

## 3. Methodology & Implementation Journey

### Architecture decision

Before writing any code I weighed three environments against each other: **Azure**, **Hetzner**, and a fully **local** approach using Docker (with Vagrant as an alternative). Hetzner was a genuinely strong cloud candidate — cheap, fast, and clean to automate — and it remains in the repository as a working second target. In the end, though, I chose the local Docker approach as the primary path for one decisive reason: it guarantees that a reviewer can run and replicate the solution instantly on their own side, with a 100% success rate and no dependency on an active cloud subscription, API tokens, or account setup. The value of the challenge is in the automation and the design, and the local path lets that speak for itself without any external prerequisites getting in the way.

### Proactive resilience and bug prevention

My goal was a flawless "one-shot" deployment, so rather than fixing problems as they appeared, I worked backwards from them. Early on I brainstormed roughly twenty to twenty-five potential edge cases and deployment blockers across both the local and cloud scenarios — things like a missing kernel setting, a Python SDK installed against the wrong interpreter, a port already in use, a stale SSH host key on a reused cloud IP, clock skew that would break certificate validation, and more. Instead of leaving these to surface at runtime, I built defensive mechanisms into the architecture up front. The clearest example is a dedicated `preflight` script that strictly validates every prerequisite before any real execution begins, and prints the exact remediation for the operator's specific OS when something is wrong. That single design choice turns a class of confusing mid-deploy failures into a clear message you get in the first few seconds.

### AI collaboration

I used AI deliberately and with a division of labour. The initial heavy lifting and the architecture design were done with **Claude**, whose stronger reasoning suited the up-front structural decisions. For iterative testing and bug fixing I switched to **Cursor** running a faster, more cost-effective "Auto" model. This was a strategic choice rather than a compromise: smaller models are perfectly capable of catching syntax and runtime errors, so using them for the repetitive edit-test loop kept Claude's advanced reasoning in reserve for the genuinely complex fixes. Matching the tool to the difficulty of the task kept the work both fast and economical.

### Testing

The deployment was exercised three times autonomously by AI agents to shake out ordering, idempotency, and environment issues, and each pass was followed by thorough manual verification on my side. The local target was taken all the way through a clean deploy, a full functional and security check, an idempotency assertion, and teardown; the cloud target was run against a real Hetzner project, which surfaced and fixed several genuine environment-specific bugs. The full account, including captured output and an honest note on what was and was not observed end to end, is in `TESTING.md`.

### Time and cost

The financial cost of this project was exactly zero. It was fully covered by my existing monthly subscriptions to Claude and Cursor, with no additional spend. My own active, hands-on time — designing the architecture, reviewing code, and steering the agents — was about six hours, tracked with a timer. This documentation itself was produced with AI assistance but written strictly to my own documentation standards, so that the result reads clearly for a human reviewer rather than like machine-generated boilerplate.

---

## 4. Future Improvements

The current solution is intentionally right-sized for the challenge. The following enhancements are the natural next steps toward a production-grade platform:

1. **Multi-node clustering and high availability.** Move from a single node to a three-node Elasticsearch cluster with dedicated master and data roles and replica shards, so the stack survives the loss of any one node. The Ansible roles already target an inventory, so this is largely an inventory and settings change rather than a rewrite.

2. **CI/CD pipeline integration.** Wire the existing lint, preflight, deploy, verify, and idempotency gates into a pipeline (for example GitHub Actions) that runs the full test suite on every push, so regressions are caught automatically and every change ships with proof that it still deploys cleanly.

3. **External secrets management.** Replace the deploy-time generated passwords and keys — currently printed once and stored under ignored paths — with a proper secrets backend such as **HashiCorp Vault** or a cloud secrets manager, giving the deployment centralized rotation, auditing, and access control.

4. **Publicly trusted certificates via ACME.** For any internet-facing deployment with a real domain, swap the internal CA for automatically issued and renewed certificates from **Let's Encrypt** (ACME), removing the browser warning while keeping HTTPS end to end.

5. **Backups, monitoring, and observability.** Add an automated snapshot and restore workflow for Elasticsearch, enable audit logging, and ship metrics and logs to a monitoring stack with alerting, so the platform is not only secure but also recoverable and observable in day-to-day operation.

---

*Layout at a glance:* `local/` and `cloud/` each contain `terraform/` (infrastructure), `ansible/` (configuration), `scripts/`, and a thin `Makefile`. To deploy, start with `./run.sh` (or `cd local && make deploy`); to tear down, use `./destroy.sh` (or `cd local && make destroy`). See `TESTING.md` for how it was tested.
