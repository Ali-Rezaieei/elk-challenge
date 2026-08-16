# TESTING

How this repository was tested, with real captured output, and an honest statement of
exactly which gates ran where.

## TL;DR — honesty up front

- **Local target — full live gate EXECUTED and PASSING.** On a rootful Docker host the
  clean deploy, `verify.sh` (10/10), and the runtime idempotency assertion
  (`changed=0`) all passed. Output below.
- **Cloud target — static gates all pass; the live path was exercised against a real
  Hetzner project** (Terraform provisioned a real VM, cloud-init gate cleared, Ansible
  configured the CA and progressed through the Elasticsearch/Kibana/nginx roles). That
  live exercise surfaced and fixed three real, environment-specific bugs (see
  [§ Bugs found and fixed](#bugs-found-and-fixed)). Live testing was stopped by the
  operator after those fixes were applied and re-validated statically, so a final
  end-to-end green `verify.sh` against the cloud endpoint was **not** captured. Every
  live attempt auto-destroyed on exit and the Hetzner project was proven empty each
  time — see [§ Cost discipline](#cost-discipline-proven).

Nothing that could be tested statically was skipped. The static gates run on both the
`local/` and `cloud/` trees.

---

## Environments covered

| Environment | Docker | Hetzner | Used for |
|-------------|--------|---------|----------|
| This Linux host, rootful Docker, ansible-core 2.16 (local), 2.21 (cloud tooling), Terraform 1.15 | Yes | Yes (live token) | Local live gate + cloud static + partial cloud live |

The developer linters (`shellcheck`, `yamllint`, `ansible-lint`, `terraform`) were
installed into a workspace-local `.tools/` sandbox so the gates are reproducible without
touching the system.

---

## Static gate (executed — both trees)

Run from a clean tree (no `.terraform/`, no state, no generated inventory, no certs, no
tfvars).

### shellcheck + bash syntax
```
$ shellcheck -x local/scripts/*.sh local/scripts/lib/*.sh \
                cloud/scripts/*.sh  cloud/scripts/lib/*.sh  run.sh
RESULT: clean (exit 0)
$ bash -n run.sh && for f in */scripts/*.sh */scripts/lib/*.sh; do bash -n "$f"; done
RESULT: all scripts parse
```

### yamllint
```
$ yamllint local/ansible local/.yamllint
$ yamllint cloud/ansible cloud/.yamllint
RESULT: clean (exit 0)
```

### ansible-lint (production profile — strictest built-in)
```
$ (cd local/ansible && ansible-lint) ; (cd cloud/ansible && ansible-lint)
Passed: 0 failure(s), 0 warning(s) ... Last profile that met the validation
criteria was 'production'.
```

### Ansible syntax-check
```
$ (cd cloud/ansible && ansible-playbook site.yml -i <generated-inv> --syntax-check)
SYNTAX OK
```

### Terraform fmt / validate
```
$ (cd cloud/terraform && terraform fmt -check && terraform init -backend=false && terraform validate)
Success! The configuration is valid.
```

### Independence between the two trees
Each side is self-contained: `local/` has no reference to `cloud/` and vice-versa, and
`run.sh` only orchestrates (it shells into whichever tree you pick). A cross-reference
grep finds no path from one tree into the other, so deleting either directory leaves the
other fully deployable.

---

## Local live gate (executed — PASSED)

Clean deploy → verify → idempotency → verify → destroy, run unattended from a genuine
zero state (`make reset && make deploy`).

### Preflight — every check green
```
== Summary ==
  PASS=27  WARN=0  FAIL=0
```
(27 checks covering tooling, the Docker Python SDK, memory/disk, `vm.max_map_count`,
cgroup v2, port availability, registry reachability, clock skew, and more.)

### verify.sh — 10/10
```
  [PASS] HTTPS edge responds and TLS validates against the internal CA
  [PASS] Plain HTTP is refused (no cleartext content served)
  [PASS] Elasticsearch cluster health is green/yellow (via /es/)
  [PASS] Kibana status is 'available'
  [PASS] Unauthenticated Elasticsearch request is rejected (proves security is ON)
  [PASS] Authenticated Elasticsearch request succeeds with generated credentials
  [PASS] Elasticsearch:9200 and Kibana:5601 are NOT reachable from the host
  [PASS] Edge certificate is unexpired and its SAN/CN covers 'localhost'
  [PASS] Kibana serves a real login page (HTTP 200, not 'server not ready')
  [PASS] Full data round trip (create index, write, search, read back, delete)
  PASS=10  FAIL=0
  URL:      https://localhost:8443/
```

### Idempotency — `changed=0` on the second run
```
elasticsearch : ok=7   changed=0   unreachable=0   failed=0
kibana        : ok=5   changed=0   unreachable=0   failed=0
localhost     : ok=8   changed=0   unreachable=0   failed=0
nginx         : ok=4   changed=0   unreachable=0   failed=0
[+] Idempotent: second run reported changed=0 and failed=0 on all hosts.
```

---

## Cloud live gate (executed against a real Hetzner project — partial)

### Preflight — every check green (19/19)
Against the live token, the full preflight passed, including the cost-discipline and
write-permission checks:
```
  [PASS] Hetzner API reachable and token is valid (HTTP 200)
  [PASS] token has WRITE permission (invalid create was validated, not forbidden)
  [PASS] project has no existing servers (safe to create exactly one)
  [PASS] no orphaned Primary IPs in the project
  [PASS] server type cx33 is offered in nbg1
  [PASS] OS image ubuntu-24.04 exists
  [PASS] hourly rate for cx33 in nbg1: ~EUR 0.0162/h (+ a Primary IPv4). ...
  [PASS] Elastic APT repository reachable (HTTP 200)
  [PASS] system clock within 0s of Hetzner (certs will validate)
  PASS=19  WARN=0  FAIL=0
```

### Infrastructure + configuration progress
```
[2/5] Provisioning infrastructure (Terraform) ...
Apply complete! Resources: 6 added, 0 changed, 0 destroyed.
[3/5] Waiting for first boot (SSH reachable) ...
[4/5] Configuring services (Ansible: cloud-init gate -> ES -> Kibana -> nginx) ...
PLAY [Generate internal CA, TLS certificates and deploy secrets]  -> all tasks OK
TASK [Block until cloud-init has finished ...]                    -> OK (marker gate)
TASK [Require the first-boot completion marker ...]              -> OK
TASK [elasticsearch : Install Elasticsearch (version-pinned) ...] -> OK
... Elasticsearch role progressed through TLS material + config rendering; the run
    then continued through the fixes below.
```

The Terraform layer (server, private network + subnet, default-deny firewall allowing
only 22/443, SSH key, Primary IP, generated inventory) provisions cleanly and the
cloud-init **marker** gate works (we wait on `/var/lib/provision/cloud-init-done`, not a
sleep, and treat cloud-init's own non-critical stock-module exit code as non-fatal).

### What was NOT captured
A final green `verify.sh` run against `https://<public-ip>/` was not captured: after the
three bugs below were found and fixed and re-validated statically, live testing was
stopped by the operator to avoid further spend. The fixes are code-level (host-key
purge, keystore create, and an inline-template correction) and are covered by the static
gates, but the definitive proof for the cloud path is a full `make deploy` on the
reviewer's Hetzner account:
```bash
cd cloud && make deploy      # preflight -> terraform -> ansible -> verify -> creds block
cd cloud && make destroy     # tears down + prints the empty-project listing
```

---

## Cost discipline (proven)

Every failed live attempt triggered the `trap cleanup EXIT INT TERM ERR` in `deploy.sh`,
which destroyed everything and printed the full project inventory. Captured from a real
run:
```
Destroy complete! Resources: 6 destroyed.
  servers:                 0
  primary_ips:             0
  floating_ips:            0
  volumes:                 0
  images?type=snapshot:    0
  images?type=backup:      0
  load_balancers:          0
  networks:                0
  firewalls:               0
```
Primary IPs (billed separately and surviving server deletion) are explicitly deleted,
and preflight refuses to run if the project already contains a server — so the design
never runs more than one VM and never leaves one behind.

---

## Bugs found and fixed

Found by the **static** gates:
1. **Terraform `%{` template-directive escaping** in a healthcheck string (`%{http_code}`
   is a Terraform template directive) — escaped to `%%{http_code}`.
2. **`set -euo pipefail` early-exit in preflight** — a failing `curl` in a pipeline
   aborted before the summary; guarded with `|| true`.
3. **ansible-lint `var-naming[no-role-prefix]`** — role `defaults`/registered vars were
   renamed with their role prefix (`elasticsearch_*`, `kibana_*`).
4. **SIGPIPE masking in `verify.sh`** — `grep -q` closing a pipe early made
   `pipefail` report the upstream `printf`/`curl` as failed; rewritten to capture output
   and match with a here-string. Applied to both trees.

Found by the **live cloud** run:
5. **Deprecated server type.** `cx32` is no longer offered; the current 8 GB shared type
   is `cx33`. Updated everywhere (variables, preflight, docs, launcher).
6. **`stdout_callback = yaml`** required `community.general`, absent in the ansible-core
   tooling — removed for portability.
7. **SSH host-key reuse.** Hetzner reuses public IPs; a stale `known_hosts` entry made
   Ansible refuse the new host ("REMOTE HOST IDENTIFICATION HAS CHANGED"). Fixed by
   `ssh-keygen -R <ip>` after `terraform apply` in `deploy.sh` and during `destroy.sh`.
8. **`ansible_managed` undefined in inline `copy` content.** `ansible_managed` is only
   injected by the `template` module, not by `copy`'s inline `content:`. The JVM-heap
   file used it and failed; replaced with a literal comment. (`.j2` files render through
   `template`, so they are unaffected.)
9. **ES keystore robustness.** Added an explicit, idempotent
   `elasticsearch-keystore create` (`creates:` guard) before seeding the bootstrap
   password, so the seed step never races the package's own keystore creation.

---

## What was NOT tested, and the honest risk

- **Cloud end-to-end `verify.sh` green run** was not captured (live testing stopped after
  the fixes). The remaining risk is environment-specific runtime behaviour on the VM
  (ES first-boot bootstrap, Kibana↔ES auth, the nginx→backend TLS chain). `verify.sh` is
  written to fail loudly rather than pass silently, so any such issue surfaces on the
  reviewer's first `make deploy`.
- **Multiple consecutive cold cloud runs / reboot-survival / SIGINT-trap live tests**
  were not run to completion for the same cost reason; the trap-based cleanup is proven
  by the auto-destroy evidence above.
