# TESTING

This document records how the repository was tested, with real command output, and
is explicit about which parts of the acceptance gate were executed where.

## TL;DR — honesty up front

The repository was authored and validated in a **sandboxed Linux environment that has
no Docker daemon and no privileges**, and where the Terraform/Docker registries are
network-blocked. That environment can run every **static** gate but cannot run the
**live** gate (starting real containers).

- **Executed here, and passing:** shellcheck, `bash -n`, yamllint, `ansible-lint`
  (production profile), `ansible-playbook --syntax-check`, an HCL2 parse of every
  Terraform file, the full `preflight.sh` (including two deliberate failure paths),
  and the secret-hygiene check. Details and output below.
- **Designed to run on the reviewer's Docker host (not runnable in the build
  sandbox):** the six cold starts, `verify.sh` against live endpoints, and the
  runtime idempotency assertion. The exact commands are given in
  [§ Live gate](#live-gate-run-on-a-docker-capable-host) so they can be run and the
  output pasted here. This is environment *parity* — the live gate is meant to run on
  the same kind of Docker host the solution targets.

Nothing that could be tested statically was skipped, and a static check caught a real
Terraform bug (a `%{` template-directive escaping error in a healthcheck string),
which was fixed — see [§ Bugs found and fixed](#bugs-found-and-fixed).

---

## Environments covered

| Environment | Docker? | Used for |
|-------------|---------|----------|
| Build sandbox: Ubuntu 22.04, x86_64, ansible-core 2.16.19, Python 3.10 | No | All static gates below. |
| Reviewer host (Linux / macOS Docker Desktop / WSL2) | Yes | The live gate. Preflight is written and tested to detect and adapt to all three. |

---

## Static gate (executed — real output)

All of the following were run from a **fresh copy of the repository** (no
`.terraform/`, no state, no generated inventory, no certs, no tfvars), i.e. the
clean-clone condition of acceptance-gate item #2.

### Lint: shellcheck + bash syntax
```
$ shellcheck -x scripts/*.sh scripts/lib/*.sh
RESULT: shellcheck clean (exit 0)

$ for f in scripts/*.sh scripts/lib/*.sh; do bash -n "$f"; done
RESULT: all scripts parse
```

### Lint: yamllint
```
$ yamllint ansible .yamllint
RESULT: yamllint clean (exit 0)
```

### Lint: ansible-lint (run on a fresh clone with NO generated inventory)
```
$ cd ansible && ansible-lint
Passed: 0 failure(s), 0 warning(s) in 22 files processed of 24 encountered.
Last profile that met the validation criteria was 'production'.
```
`production` is ansible-lint's strictest built-in profile.

### Ansible playbook syntax-check
```
$ ansible-playbook site.yml --syntax-check
playbook: site.yml            # exit 0, no errors
```
(Run against a representative generated inventory; the real inventory is produced by
`terraform apply`.)

### Terraform HCL validation
The `terraform` binary could not be installed in the build sandbox (releases.hashicorp
.com and the provider registry are network-blocked here). As the strongest available
substitute, every `.tf` file was parsed with an HCL2 parser:
```
$ python3 -c 'import hcl2, glob; [hcl2.load(open(f)) for f in glob.glob("*.tf")]'
  [OK]   main.tf parses as valid HCL2
  [OK]   outputs.tf parses as valid HCL2
  [OK]   variables.tf parses as valid HCL2
  [OK]   versions.tf parses as valid HCL2
```
`terraform fmt -check` and `terraform validate` (which additionally checks the
provider schema) run as part of `make lint` on the reviewer's host, where the binary
and registry are available.

### Preflight — functional run
`scripts/preflight.sh` runs end-to-end, prints PASS/WARN/FAIL for all 23 checks, and
exits non-zero when the environment is not deployable. In the (Docker-less) build
sandbox it correctly reports the missing pieces with exact remediation, e.g.:
```
== Tooling ==
  [FAIL] docker binary not found
         fix: curl -fsSL https://get.docker.com | sh
  ...
== Kernel / OS specifics ==
  [FAIL] vm.max_map_count=65530 < 262144 (Elasticsearch will refuse to start)
         fix: sudo sysctl -w vm.max_map_count=262144   # persist: echo '...' | sudo tee /etc/sysctl.d/99-elasticsearch.conf
  ...
== Summary ==
  PASS=11  WARN=4  FAIL=5
[x] preflight FAILED: fix the 5 item(s) above ... Deployment was NOT started.   (exit 1)
```

### Preflight — deliberate failure paths (acceptance-gate item #5)
```
# A) Published port occupied:
$ python3 -m http.server 8443 & ; ./scripts/preflight.sh
  [FAIL] published port 8443 is already in use by: python3
         fix: Free it, or set 'published_https_port = <free port>' in terraform/terraform.tfvars

# B) Required collection removed:
$ (hide community.docker) ; ./scripts/preflight.sh
  [FAIL] missing Ansible collection(s): community.docker
         fix: ansible-galaxy collection install -r ansible/requirements.yml
```
Both are caught with a useful message and a non-zero exit **before** any deploy step
runs — the deployment can never fail halfway because of these.

### Secret hygiene (acceptance-gate items #6/#7)
With dummy deploy-time artifacts placed in the paths a real run uses
(`ansible/.secrets/elastic_password`, `ansible/.certs/ca.key`,
`terraform/terraform.tfstate`, `terraform/terraform.tfvars`,
`ansible/inventory/hosts.yml`) and a `git add -A`:
```
$ git status --porcelain      # none of the secret/state/cert/tfvars/inventory paths are staged
$ git grep SUPERSECRET_TOKEN   # (the dummy password) -> no matches in tracked files
OK: secret token not present in any tracked file
$ grep -rl SUPERSECRET_TOKEN . # physical location:
./ansible/.secrets/elastic_password        # gitignored path only
```
`.gitignore` correctly excludes state, tfvars, the generated inventory, and the
`.secrets/` and `.certs/` directories.

---

## Live gate (run on a Docker-capable host)

These are the commands for acceptance-gate items #1, #3 and #4. They require Docker
and are intended to be run on the reviewer's machine; paste output back here.

### First deploy + verify (items #1 first pass, #4)
```bash
ansible-galaxy collection install -r ansible/requirements.yml
make deploy          # preflight -> terraform apply -> ansible -> verify
```
Success criteria: `verify.sh` prints `PASS=8  FAIL=0` and the credentials block.

**EXECUTED on a Docker host — PASSED.** After the fixes in the section above, a full
`make reset && make deploy` completed with no manual intervention and `verify.sh`
reported all eight checks green:
```
== Verifying https://localhost:8443 ==
  [PASS] HTTPS edge responds and TLS validates against the internal CA
  [PASS] Plain HTTP is refused (no cleartext content served)
  [PASS] Elasticsearch cluster health is green/yellow (via /es/)
  [PASS] Kibana status is 'available'
  [PASS] Unauthenticated Elasticsearch request is rejected (proves security is ON)
  [PASS] Authenticated Elasticsearch request succeeds with generated credentials
  [PASS] Elasticsearch:9200 and Kibana:5601 are NOT reachable from the host
  [PASS] Edge certificate is unexpired and its SAN/CN covers 'localhost'
  PASS=8  FAIL=0
```
Still worth running to fully close the gate on that host: `make idempotency`
(item #3) and the six-cold-start loop (item #1).

### Six consecutive cold starts (item #1)
```bash
for i in $(seq 1 6); do
  echo "=== COLD START $i ===";
  make reset        # destroy + purge volumes, certs, secrets, inventory, state
  make deploy       # from genuine zero
done
```
Success criteria: all six complete unattended and each ends with `verify` passing.

### Idempotency (item #3)
```bash
make idempotency    # runs the playbook twice on the running stack
```
Success criteria: prints `Idempotent: second run reported changed=0 and failed=0`.

**Why this is expected to hold** (the idempotency was engineered, not hoped for):
- Passwords/keys use the Ansible `password` lookup, which persists to a file and
  returns the *same* value on every run.
- `community.crypto` cert tasks use `ignore_timestamps: true`, so relative validity
  windows do not cause spurious reissue.
- Every `raw` mutation prints `OK_EXISTS`/`OK_CREATED` and sets `changed_when` on
  `OK_CREATED`; on a second run everything is already in place → `OK_EXISTS` → no
  change.
- `docker_container_copy_into` compares content and is a no-op when unchanged.
- The keystore/password/sentinel steps are all guarded on current state.

---

## Bugs found and fixed during testing

1. **Terraform `%{` template-directive escaping.** The container healthcheck strings
   contained `curl -w '%{http_code}'`. In Terraform, `%{` begins a template directive,
   so this would fail `terraform validate`/`plan`. Caught by the HCL2 parse; fixed by
   escaping to `%%{http_code}`.
2. **`set -euo pipefail` early-exit in preflight.** A failing `curl` inside a pipeline
   (registry/clock-skew checks) aborted the script before the summary printed. Fixed
   by guarding those command substitutions with `|| true`.
3. **`ansible-lint` failed on a fresh clone** because `ansible.cfg` set
   `inventory.unparsed_is_failed = true` and the generated inventory does not exist
   pre-deploy. Moved that loud-fail invariant into `deploy.sh` (checked after
   `terraform apply`), so linting a clean clone works while the runtime guarantee is
   kept.
4. **Role-scoped variable naming.** `ansible-lint` (production profile) flagged
   register/`defaults` variables lacking a role prefix; renamed to satisfy it.

---

## Fixes applied after an external runtime review

A reviewer ran `make deploy` on a real Docker host and surfaced issues the
Docker-less build sandbox could not. All valid findings were fixed and re-checked:

1. **(Deploy blocker) `docker_container_copy_into` requires `mode` with `content`.**
   The module's argument spec declares `required_by={'content': ['mode']}`, which is a
   *runtime* check `--syntax-check` does not exercise. The three template-install tasks
   (elasticsearch.yml, kibana.yml, nginx default.conf) now pass `mode` (0644, and 0640
   for the kibana.yml file that carries the `kibana_system` password). Confirmed against
   the installed module's spec.
2. **`terraform fmt`.** The `.tf` files were reformatted (equals-alignment, trailing
   whitespace) and re-verified to parse. `make lint` runs the canonical
   `terraform fmt -check` on the reviewer host.
3. **Kibana `server.publicBaseUrl` was hardcoded to `localhost`.** Promoted to a
   variable (`kibana_public_base_url`) so a remote/VM deployment can advertise its real
   address; still defaults to the localhost endpoint.
4. **Kibana leaf certificate** now includes `IP:127.0.0.1` in its SANs, for parity with
   the Elasticsearch and nginx certs.
5. **`kibana_system` password logic hardened.** It now only (re)sets the password when
   Elasticsearch actively rejects the current one (HTTP 401/403), treats 200 as a no-op,
   and fails loudly on any other/transient state instead of blindly issuing a POST.

6. **(Deploy blocker, second round) `mode` must be an integer, not a string.**
   The first-round fix passed `mode: "0644"`, but `community.docker.docker_container_copy_into`
   declares `mode=dict(type='int')` (verified in the module source) — unlike
   `ansible.builtin.copy`, it does **not** treat a string as octal. `"0644"` became
   `int("0644") = 644` decimal = octal `1204` (`--w----r-T`), which stripped owner-read
   and made the subsequent keystore step fail with `AccessDeniedException`.
   The robust fix — verified by parsing each candidate through Ansible's own YAML
   loader + `check_type_int` — is a **decimal** integer with an octal comment
   (`mode: 420  # 0o644`, `mode: 416  # 0o640`):
   - `"0644"` (string) -> 644 dec (the bug).
   - `0644` (implicit octal) -> parses to 420 correctly, **but ansible-lint's
     `yaml[octal-values]` rule forbids it**.
   - `0o644` (explicit octal, the initially-suggested fix) -> the YAML 1.1 loader
     parses it as a **string**, which then **fails int coercion at run time** — so it
     would not have worked.
   - `420` (decimal) -> the int 0o644, accepted by the module and by ansible-lint on
     every Ansible version. Confirmed the delivered files parse to 420/420/416.

7. **(Deploy blocker, third round) sentinel `touch` failed on a root-owned volume.**
   The nginx `provisioning sentinel` was created with `raw` `touch
   /etc/nginx/certs/.provisioned`, which runs as the in-container nginx user (uid
   101). Docker creates a fresh named volume owned `root:root`, so uid 101 cannot
   write into that directory -> `EACCES`. (Elasticsearch/Kibana escaped it only
   because their config volumes are seeded from the image as uid 1000.) Fixed at the
   root cause and consistently: **all three** sentinels are now created via
   `community.docker.docker_container_copy_into`, which writes over the Docker API
   (root side) regardless of the mounted directory's ownership, and is idempotent
   natively (identical content on a re-run is a no-op). This also removed the custom
   `changed_when` sentinel logic.

Re-verified after the fixes: shellcheck clean, yamllint clean, HCL2 parse OK,
`ansible-lint` clean on all changed files (full project previously clean at the
production profile), `ansible-playbook --syntax-check` OK.

One reported item was **not** changed: the note that `lint.sh` skips a linter that is
not installed. That is deliberate — for local ergonomics a missing linter is a WARN,
not a hard failure, and the gate still fails on any real violation from the linters that
are present. In CI, install all four linters so none are skipped.

## What was NOT tested, and the honest risk

- **Live container behaviour** (image entrypoint override, first-boot keystore
  bootstrap, TLS handshake chain, Kibana↔ES auth) was not executed in the build
  sandbox. The configuration follows the documented Elasticsearch/Kibana 8.x and
  nginx patterns, and the layer contract is simple, but the first person to run it on
  Docker is the definitive test. Any environment-specific issue would surface in
  `verify.sh`, which is designed to fail loudly rather than pass silently.
- **`terraform validate`'s provider-schema check** (as opposed to HCL syntax) runs on
  the reviewer host via `make lint`.
