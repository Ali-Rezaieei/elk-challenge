#!/usr/bin/env bash
# ===========================================================================
# preflight.sh (cloud) - validate EVERYTHING before any billable API call.
# Non-mutating: it only reads (plus one harmless invalid POST to detect a
# read-only token). Every FAIL prints an exact copy-pasteable fix and the
# script exits non-zero, so a broken environment can never reach a paid apply.
# ===========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"

MIN_TERRAFORM_VERSION="1.5.0"
MIN_ANSIBLE_VERSION="2.15.0"

PROJECT_PREFIX="$(read_tfvar project_prefix elk-cloud)"
LOCATION="$(read_tfvar location nbg1)"
SERVER_TYPE="$(read_tfvar server_type cx33)"
SERVER_IMAGE="$(read_tfvar server_image ubuntu-24.04)"
SSH_PUB="$(read_tfvar ssh_public_key_path "${HOME}/.ssh/id_ed25519.pub")"
SSH_KEY="$(read_tfvar ssh_private_key_path "${HOME}/.ssh/id_ed25519")"
# Expand a leading ~ that may come from tfvars.
SSH_PUB="${SSH_PUB/#\~/$HOME}"
SSH_KEY="${SSH_KEY/#\~/$HOME}"

PASS_COUNT=0; WARN_COUNT=0; FAIL_COUNT=0
pass() { PASS_COUNT=$((PASS_COUNT+1)); printf '  %s[PASS]%s %s\n' "$C_GREEN" "$C_RESET" "$1"; }
warn() { WARN_COUNT=$((WARN_COUNT+1)); printf '  %s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$1"; }
fail() {
  FAIL_COUNT=$((FAIL_COUNT+1)); printf '  %s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$1"
  if [ -n "${2:-}" ]; then printf '         %sfix:%s %s\n' "$C_BOLD" "$C_RESET" "$2"; fi
}
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }

section "Cloud preflight (project=${PROJECT_PREFIX} type=${SERVER_TYPE} location=${LOCATION} image=${SERVER_IMAGE})"

# ======================== LOCAL TOOLING ===================================
section "Tooling"

if ! command -v terraform >/dev/null 2>&1; then
  fail "terraform not found" "See https://developer.hashicorp.com/terraform/install"
else
  TF_VER="$(terraform version -json 2>/dev/null | sed -n 's/.*"terraform_version":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  [ -n "$TF_VER" ] || TF_VER="$(terraform version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
  if [ -n "$TF_VER" ] && ver_ge "$TF_VER" "$MIN_TERRAFORM_VERSION"; then
    pass "terraform ${TF_VER} >= ${MIN_TERRAFORM_VERSION}"
  else
    fail "terraform ${TF_VER:-unknown} < ${MIN_TERRAFORM_VERSION}" "Upgrade terraform to >= ${MIN_TERRAFORM_VERSION}"
  fi
fi

if ! command -v ansible-playbook >/dev/null 2>&1; then
  fail "ansible-playbook not found" "pipx install ansible-core   # or your distro package"
else
  ANS_VER="$(ansible-playbook --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  if [ -n "$ANS_VER" ] && ver_ge "$ANS_VER" "$MIN_ANSIBLE_VERSION"; then
    pass "ansible-core ${ANS_VER} >= ${MIN_ANSIBLE_VERSION}"
  else
    fail "ansible-core ${ANS_VER:-unknown} < ${MIN_ANSIBLE_VERSION}" "pipx upgrade ansible-core"
  fi
fi

for tool in curl openssl python3 ssh; do
  if command -v "$tool" >/dev/null 2>&1; then pass "${tool} present"
  else fail "${tool} not present" "Install ${tool} with your package manager"; fi
done

if command -v ansible-galaxy >/dev/null 2>&1; then
  COLL_LIST="$(ANSIBLE_COLLECTIONS_PATH="${ANS_DIR}/collections:${HOME}/.ansible/collections" \
    ansible-galaxy collection list 2>/dev/null || true)"
  missing=""
  for c in community.crypto ansible.posix; do
    echo "$COLL_LIST" | grep -q "^${c} " || missing="${missing} ${c}"
  done
  if [ -z "$missing" ]; then pass "required Ansible collections present (community.crypto, ansible.posix)"
  else fail "missing Ansible collection(s):${missing}" "ansible-galaxy collection install -r ansible/requirements.yml -p ansible/collections"; fi
fi

# ======================== SSH KEY =========================================
section "SSH key"

if [ ! -f "$SSH_PUB" ]; then
  fail "SSH public key not found at ${SSH_PUB}" "ssh-keygen -t ed25519 -f ${SSH_KEY} -C elk-cloud   # then re-run"
elif ! ssh-keygen -l -f "$SSH_PUB" >/dev/null 2>&1; then
  fail "SSH public key at ${SSH_PUB} is not a valid key" "Regenerate: ssh-keygen -t ed25519 -f ${SSH_KEY}"
else
  pass "SSH public key present and valid (${SSH_PUB})"
fi

if [ -f "$SSH_KEY" ]; then
  # Permissions must be 0600 (owner-only) or the key must be loaded in an agent.
  PERM="$(stat -c '%a' "$SSH_KEY" 2>/dev/null || stat -f '%Lp' "$SSH_KEY" 2>/dev/null || echo '')"
  if [ "$PERM" = "600" ] || [ "$PERM" = "400" ]; then
    pass "SSH private key permissions are ${PERM}"
  else
    fail "SSH private key ${SSH_KEY} has permissions ${PERM:-unknown} (must be 600)" "chmod 600 ${SSH_KEY}"
  fi
  # Passphrase-protected key without a loaded agent makes Ansible hang silently.
  if ssh-keygen -y -P "" -f "$SSH_KEY" >/dev/null 2>&1; then
    pass "SSH private key has no passphrase (Ansible will not hang)"
  elif ssh-add -l >/dev/null 2>&1; then
    pass "SSH private key is passphrase-protected but an agent is loaded"
  else
    fail "SSH private key is passphrase-protected and no agent is loaded (Ansible would hang while the server bills)" \
         "eval \"\$(ssh-agent -s)\" && ssh-add ${SSH_KEY}"
  fi
else
  warn "SSH private key not found at ${SSH_KEY}; Ansible needs it to connect (Terraform only needs the .pub)"
fi

# ======================== HETZNER TOKEN + PROJECT =========================
section "Hetzner Cloud"

load_hcloud_token
if [ -z "${HCLOUD_TOKEN:-}" ]; then
  fail "HCLOUD_TOKEN is not set and no token in cloud/.env" \
       "export HCLOUD_TOKEN=<token>   # create one at console.hetzner.cloud -> Security -> API tokens (Read & Write)"
  # Nothing below works without a token; summarise and exit.
  section "Summary"
  printf '  %sPASS=%d  WARN=%d  FAIL=%d%s\n' "$C_BOLD" "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT" "$C_RESET"
  die "preflight FAILED: no API token. Deployment was NOT started."
fi

# Outbound HTTPS + token validity in one read-only call.
CODE="$(hc_get_code /ssh_keys || echo 000)"
case "$CODE" in
  200) pass "Hetzner API reachable and token is valid (HTTP 200)" ;;
  401) fail "Hetzner API rejected the token (HTTP 401 - invalid or expired)" \
            "Generate a fresh Read & Write token at console.hetzner.cloud -> Security -> API tokens" ;;
  000) fail "cannot reach the Hetzner API (no outbound HTTPS to api.hetzner.cloud)" \
            "Check your network/proxy; the control node needs outbound 443 to api.hetzner.cloud" ;;
  *)   fail "unexpected response from the Hetzner API (HTTP ${CODE})" "Retry; if it persists check https://status.hetzner.com" ;;
esac

# Detect a read-only token BEFORE apply: an invalid POST returns 422 with a
# write token but 403 with a read-only one. Creates nothing.
if [ "$CODE" = "200" ]; then
  WCODE="$(hc_post_code /ssh_keys '{}' || echo 000)"
  case "$WCODE" in
    422|400) pass "token has WRITE permission (invalid create was validated, not forbidden)" ;;
    403)     fail "token is READ-ONLY (a create returned HTTP 403 forbidden)" \
                  "Create a Read & Write token at console.hetzner.cloud -> Security -> API tokens" ;;
    201|200) warn "unexpected: a stray SSH key may have been created; destroy.sh will list it" ;;
    *)       warn "could not conclusively verify write permission (HTTP ${WCODE}); apply will confirm" ;;
  esac

  # Project must be empty of billable resources (cost discipline: never >1 server).
  SRV="$(hc_count /servers servers)"
  if [ "$SRV" = "0" ]; then
    pass "project has no existing servers (safe to create exactly one)"
  elif [ "$SRV" = "-1" ]; then
    warn "could not read the current server count; proceed with care"
  else
    fail "project already has ${SRV} server(s); never run more than one at a time" \
         "Tear the existing one down first:  ./scripts/destroy.sh"
  fi

  # Orphaned Primary IPs are billed separately and are the classic silent charge.
  PIP="$(hc_count /primary_ips primary_ips)"
  if [ "$PIP" = "0" ] || [ "$PIP" = "-1" ]; then
    pass "no orphaned Primary IPs in the project"
  else
    warn "project has ${PIP} Primary IP(s) (billed separately). destroy.sh removes ours; review with the console if unexpected"
  fi

  # Server type must be offered in the chosen location.
  if hc_get "/server_types?name=${SERVER_TYPE}" 2>/dev/null | grep -q "\"${LOCATION}\""; then
    pass "server type ${SERVER_TYPE} is offered in ${LOCATION}"
  else
    ALT="$(hc_get "/server_types?name=${SERVER_TYPE}" 2>/dev/null | grep -oE '"location":"[a-z0-9]+"' | sed 's/"location":"//;s/"//' | sort -u | tr '\n' ' ' || true)"
    fail "server type ${SERVER_TYPE} does not appear available in ${LOCATION}" \
         "Set location to one of: ${ALT:-nbg1 fsn1 hel1} in terraform/terraform.tfvars"
  fi

  # Image must exist.
  IMG="$(hc_count "/images?type=system&name=${SERVER_IMAGE}" images)"
  if [ "$IMG" != "0" ] && [ "$IMG" != "-1" ]; then
    pass "OS image ${SERVER_IMAGE} exists"
  else
    fail "OS image ${SERVER_IMAGE} not found" "Pick a valid image name (e.g. ubuntu-24.04) in terraform/terraform.tfvars"
  fi

  # Cost transparency: print the hourly rate + a one-cycle estimate.
  HOURLY="$(hc_get "/server_types?name=${SERVER_TYPE}" 2>/dev/null | python3 -c "import sys,json
try:
    d=json.load(sys.stdin); st=d['server_types'][0]
    p=[x for x in st.get('prices',[]) if x.get('location')=='${LOCATION}']
    print(p[0]['price_hourly']['gross'] if p else '')
except Exception:
    print('')" 2>/dev/null || true)"
  if [ -n "$HOURLY" ]; then
    pass "hourly rate for ${SERVER_TYPE} in ${LOCATION}: ~EUR $(printf '%.4f' "$HOURLY")/h (+ a Primary IPv4). A short deploy+destroy cycle costs a few cents."
  else
    warn "could not read the live price; ${SERVER_TYPE} is roughly EUR 0.02-0.03/hour incl. IPv4"
  fi
fi

# Elastic APT repo reachability (the SERVER needs it, but a control-node check
# catches an obviously broken egress early).
ELASTIC_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 https://artifacts.elastic.co/packages/8.x/apt/dists/stable/Release 2>/dev/null || echo 000)"
if [ "$ELASTIC_CODE" = "200" ]; then
  pass "Elastic APT repository reachable (HTTP 200)"
else
  warn "could not confirm the Elastic APT repo from here (HTTP ${ELASTIC_CODE}); the server needs outbound 443 to artifacts.elastic.co"
fi

# Clock skew (cert validity depends on it) using the API Date header.
REMOTE_DATE="$(curl -sI --max-time 8 "${HCLOUD_API}/locations" 2>/dev/null | awk -F': ' 'tolower($1)=="date"{print $2}' | tr -d '\r' || true)"
if [ -n "$REMOTE_DATE" ]; then
  REMOTE_EPOCH="$(date -d "$REMOTE_DATE" +%s 2>/dev/null || echo 0)"
  if [ "$REMOTE_EPOCH" != "0" ]; then
    SKEW=$(( $(date +%s) - REMOTE_EPOCH )); SKEW=${SKEW#-}
    if [ "$SKEW" -le 120 ]; then pass "system clock within ${SKEW}s of Hetzner (certs will validate)"
    else fail "system clock off by ~${SKEW}s; TLS validity checks may fail" "Sync your clock (sudo chronyc makestep / sudo hwclock -s)"; fi
  fi
else
  warn "could not measure clock skew; ensure your clock is correct so certs validate"
fi

section "Summary"
printf '  %sPASS=%d  WARN=%d  FAIL=%d%s\n' "$C_BOLD" "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT" "$C_RESET"
if [ "$FAIL_COUNT" -gt 0 ]; then
  log_err "cloud preflight FAILED: fix the ${FAIL_COUNT} item(s) above. Nothing was provisioned."
  exit 1
fi
log_ok "cloud preflight passed (${WARN_COUNT} warning(s)). Safe to deploy."
exit 0
