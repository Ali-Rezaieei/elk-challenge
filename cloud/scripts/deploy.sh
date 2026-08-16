#!/usr/bin/env bash
# ===========================================================================
# deploy.sh (cloud) - stand up the stack on Hetzner:
#   preflight -> terraform apply -> wait for first boot -> ansible -> verify
#
# COST DISCIPLINE: before apply we confirm the project has zero servers, and a
# trap on INT/TERM/ERR destroys anything provisioned if the run does not finish
# successfully - an abort can never leave a server billing.
#
# Modes:
#   ./scripts/deploy.sh                       full deploy + verify
#   ./scripts/deploy.sh --idempotency-check   run Ansible twice; assert changed=0
# ===========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"
load_hcloud_token

MODE="deploy"
[ "${1:-}" = "--idempotency-check" ] && MODE="idempotency"

export ANSIBLE_COLLECTIONS_PATH="${ANS_DIR}/collections:${HOME}/.ansible/collections"

PROVISIONED=0
SUCCESS=0
cleanup() {
  local rc=$?
  trap - EXIT INT TERM ERR
  if [ "$SUCCESS" != "1" ] && [ "$PROVISIONED" = "1" ]; then
    log_warn "Deploy did not complete cleanly; collecting diagnostics then destroying to avoid a server that keeps billing..."
    "${SCRIPT_DIR}/destroy.sh" --diagnostics || log_err "Automatic cleanup FAILED - open console.hetzner.cloud and delete the server + its Primary IP by hand."
  fi
  exit "$rc"
}

bootstrap_collections() {
  section "Installing declared Ansible collections"
  ansible-galaxy collection install -r "${ANS_DIR}/requirements.yml" -p "${ANS_DIR}/collections" >/dev/null
  log_ok "collections ready"
}

run_ansible() { ( cd "$ANS_DIR" && ansible-playbook site.yml ); }

print_credentials() {
  section "Access details"
  local url ep ip
  url="$( (cd "$TF_DIR" && terraform output -raw https_url 2>/dev/null) || echo '')"
  ip="$( (cd "$TF_DIR" && terraform output -raw server_ipv4 2>/dev/null) || echo '')"
  ep="${ANS_DIR}/.secrets/elastic_password"
  printf '  URL:        %s\n' "${url:-https://<server-ip>/}"
  printf '  Public IP:  %s\n' "${ip:-unknown}"
  printf '  Username:   elastic\n'
  if [ -f "$ep" ]; then printf '  Password:   %s\n' "$(cat "$ep")"; else printf '  Password:   (not found at %s)\n' "$ep"; fi
  printf '\n  The browser will warn about the certificate: the edge cert is signed by\n'
  printf '  this deploy'\''s internal CA. That is expected.\n'
  printf '\n  %sThis is a real server and it costs money. Tear it down when done:%s\n' "$C_BOLD" "$C_RESET"
  printf '    ./run.sh   ->  Destroy       (or)      cd cloud && make destroy\n'
}

# ---------------------------- IDEMPOTENCY ---------------------------------
if [ "$MODE" = "idempotency" ]; then
  section "Idempotency check: running the playbook twice against the live server"
  log_info "First run..."
  run_ansible >/dev/null
  log_info "Second run (must be a no-op)..."
  RECAP="$(run_ansible | tee /dev/stderr | grep -E 'changed=[0-9]+.*failed=[0-9]+' || true)"
  if echo "$RECAP" | grep -qE 'changed=[1-9]'; then die "Idempotency FAILED: second run reported changes:
${RECAP}"; fi
  if echo "$RECAP" | grep -qE 'failed=[1-9]'; then die "Idempotency FAILED: second run reported failures:
${RECAP}"; fi
  log_ok "Idempotent: second run reported changed=0 and failed=0."
  exit 0
fi

# ------------------------------ FULL DEPLOY -------------------------------
trap cleanup EXIT INT TERM ERR
START_TS="$(date +%s)"

bootstrap_collections

printf '\n%s[1/5] Checking environment ...%s\n' "$C_BOLD" "$C_RESET"
"${SCRIPT_DIR}/preflight.sh"

# Cost discipline: never more than one server. Refuse if the project is not empty.
SRV="$(hc_count /servers servers)"
if [ "$SRV" != "0" ] && [ "$SRV" != "-1" ]; then
  die "Refusing to apply: the project already has ${SRV} server(s). Tear down first: ./scripts/destroy.sh"
fi

printf '\n%s[2/5] Provisioning infrastructure (Terraform) ...%s\n' "$C_BOLD" "$C_RESET"
(
  cd "$TF_DIR"
  terraform init -input=false >/dev/null
)
PROVISIONED=1   # from here on, an abort must destroy
( cd "$TF_DIR" && terraform apply -auto-approve -input=false )

[ -f "${ANS_DIR}/inventory/hosts.yml" ] || die "Terraform did not produce the Ansible inventory - aborting before Ansible."
SERVER_IP="$( (cd "$TF_DIR" && terraform output -raw server_ipv4) )"
log_ok "Server provisioned at ${SERVER_IP}; inventory generated from state."

printf '\n%s[3/5] Waiting for first boot (SSH reachable) ...%s\n' "$C_BOLD" "$C_RESET"
# Bounded wait for the SSH port; Ansible then gates authoritatively on the
# cloud-init completion signal (never a bare sleep).
DEADLINE=$(( $(date +%s) + 300 ))
until (exec 3<>"/dev/tcp/${SERVER_IP}/22") 2>/dev/null; do
  [ "$(date +%s)" -lt "$DEADLINE" ] || die "SSH on ${SERVER_IP}:22 not reachable within 300s"
  sleep 5
done
exec 3>&- 2>/dev/null || true
log_ok "SSH port is open."

printf '\n%s[4/5] Configuring services (Ansible: cloud-init gate -> ES -> Kibana -> nginx) ...%s\n' "$C_BOLD" "$C_RESET"
run_ansible

printf '\n%s[5/5] Verifying ...%s\n' "$C_BOLD" "$C_RESET"
"${SCRIPT_DIR}/verify.sh"

print_credentials
ELAPSED=$(( $(date +%s) - START_TS ))
section "Done in ${ELAPSED}s"
log_ok "Cloud stack is up. Remember it bills until you destroy it."
SUCCESS=1
