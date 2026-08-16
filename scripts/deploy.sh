#!/usr/bin/env bash
# ===========================================================================
# deploy.sh - one command to stand the whole stack up:
#   (bootstrap deps) -> preflight -> terraform apply -> ansible -> verify
#
# Modes:
#   ./scripts/deploy.sh                     full deploy + verify
#   ./scripts/deploy.sh --idempotency-check run Ansible twice on a running
#                                           stack; assert the 2nd run changed=0
# ===========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"

MODE="deploy"
[ "${1:-}" = "--idempotency-check" ] && MODE="idempotency"

TF_DIR="${REPO_ROOT}/terraform"
ANS_DIR="${REPO_ROOT}/ansible"
# Keep vendored collections inside the repo (matches ansible.cfg).
export ANSIBLE_COLLECTIONS_PATH="${ANS_DIR}/collections:${HOME}/.ansible/collections"

# --- Dependency bootstrap: install declared collections up front so the happy
# path is smooth. (preflight, run next, still FAILS standalone if they are
# missing - that is what the failure-path test exercises.) ------------------
bootstrap_collections() {
  section "Installing declared Ansible collections"
  ansible-galaxy collection install -r "${ANS_DIR}/requirements.yml" \
    -p "${ANS_DIR}/collections" >/dev/null
  log_ok "collections ready"
}

run_ansible() { # run the site playbook from the ansible dir
  ( cd "$ANS_DIR" && ansible-playbook site.yml )
}

print_credentials() {
  section "Access details"
  local port ep
  port="$( (cd "$TF_DIR" && terraform output -raw https_url 2>/dev/null) || echo "https://localhost:8443/")"
  ep="${ANS_DIR}/.secrets/elastic_password"
  printf '  URL:      %s\n' "$port"
  printf '  Username: %s\n' "elastic"
  if [ -f "$ep" ]; then
    printf '  Password: %s\n' "$(cat "$ep")"
  else
    printf '  Password: (not found at %s)\n' "$ep"
  fi
  printf '\n  The Kibana login page will show a browser certificate warning: the\n'
  printf '  edge cert is signed by this deploy'\''s internal CA. Trust ansible/.certs/ca.crt\n'
  printf '  to remove it. See README -> "What to expect on first access".\n'
}

if [ "$MODE" = "idempotency" ]; then
  # Assumes the stack is already deployed and running.
  section "Idempotency check: running the playbook twice against the running stack"
  log_info "First run (may report changes if something drifted)..."
  run_ansible >/dev/null
  log_info "Second run (must be a no-op)..."
  RECAP="$(run_ansible | tee /dev/stderr | grep -E 'changed=[0-9]+.*failed=[0-9]+' || true)"
  # Every host line must show changed=0 and failed=0.
  if echo "$RECAP" | grep -qE 'changed=[1-9]'; then
    die "Idempotency FAILED: the second run reported changes:
${RECAP}"
  fi
  if echo "$RECAP" | grep -qE 'failed=[1-9]'; then
    die "Idempotency FAILED: the second run reported failures:
${RECAP}"
  fi
  log_ok "Idempotent: second run reported changed=0 and failed=0 on all hosts."
  exit 0
fi

# ----------------------------- FULL DEPLOY --------------------------------
START_TS="$(date +%s)"

bootstrap_collections

section "Preflight"
"${SCRIPT_DIR}/preflight.sh"

section "Terraform: provisioning infrastructure"
(
  cd "$TF_DIR"
  terraform init -input=false >/dev/null
  terraform apply -auto-approve -input=false
)
# Enforce the layer-handover invariant: Ansible must never run against a missing
# inventory (which would "succeed" with zero tasks). This is the loud-fail we
# deliberately keep out of ansible.cfg so it does not break linting a fresh clone.
[ -f "${ANS_DIR}/inventory/hosts.yml" ] || \
  die "Terraform did not produce ${ANS_DIR}/inventory/hosts.yml — aborting before Ansible."
log_ok "Infrastructure provisioned; Ansible inventory generated from state."

section "Ansible: configuring services (this is where first-boot waits happen)"
run_ansible

section "Verify"
"${SCRIPT_DIR}/verify.sh"

print_credentials

ELAPSED=$(( $(date +%s) - START_TS ))
section "Done in ${ELAPSED}s"
log_ok "Stack is up. Open the URL above."
