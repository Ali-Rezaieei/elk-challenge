#!/usr/bin/env bash
# ===========================================================================
# destroy.sh - the single entry point for TEARING DOWN this repository.
#
# Deploy lives in ./run.sh; teardown lives here, on purpose. Keeping the two
# apart means a destroy is always a deliberate, explicit act - never a menu
# item you can hit by accident during a deploy session.
#
# Like run.sh, this only ORCHESTRATES: the real work is each target's own
# `make destroy` / `make reset` (Terraform destroy + a scoped Docker/API
# sweep, and - for reset - purging generated certs/secrets/inventory/state).
#
# Compatible with bash 3.2 (macOS) and Linux: no associative arrays, no
# readarray. set -euo pipefail throughout; colour only on a TTY.
# ===========================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_DIR="${ROOT_DIR}/local"
CLOUD_DIR="${ROOT_DIR}/cloud"
HCLOUD_API="https://api.hetzner.cloud/v1"

# --- Colour (only when stdout is a TTY and NO_COLOR is unset) ---------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && command -v tput >/dev/null 2>&1 \
  && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  C_RED="$(tput setaf 1)"; C_GREEN="$(tput setaf 2)"; C_YELLOW="$(tput setaf 3)"
  C_BLUE="$(tput setaf 4)"; C_BOLD="$(tput bold)"; C_RESET="$(tput sgr0)"
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""; C_RESET=""
fi
info() { printf '%s[*]%s %s\n' "$C_BLUE" "$C_RESET" "$*" >&2; }
ok()   { printf '%s[+]%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
warn() { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
hr()   { printf '%s%s%s\n' "$C_BOLD" "------------------------------------------------------------" "$C_RESET"; }
lower(){ printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

on_interrupt() {
  printf '\n'
  warn "Interrupted before teardown finished."
  warn "Re-run ./destroy.sh to make sure nothing is left behind (a cloud server keeps billing)."
  exit 130
}
trap on_interrupt INT TERM

usage() {
  cat <<EOF
Usage: ./destroy.sh [options]

Interactive (no options): shows what is deployed and walks you through teardown.

Non-interactive:
  ./destroy.sh --target <local|cloud> [--purge] [--yes]

Options:
  --target   local | cloud
  --purge    also delete generated certs/secrets/inventory/state (a true cold
             start - i.e. 'make reset' instead of 'make destroy')
  --yes      assume yes / skip confirmations
  --help     show this help

Examples:
  ./destroy.sh
  ./destroy.sh --target local --yes
  ./destroy.sh --target cloud --purge --yes

To deploy, use ./run.sh (or 'cd local && make deploy').
EOF
}

# --- Rule: do not run as root ----------------------------------------------
# Root-owned Terraform state / .terraform / Ansible caches break later runs as
# the normal user. Teardown should stay as the same user that deployed.
check_not_root() {
  local uid; uid="$(id -u)"
  [ "$uid" -ne 0 ] && return 0
  err "destroy.sh is running as root (uid 0)."
  if [ -n "${SUDO_USER:-}" ]; then
    err "It looks invoked via sudo by '${SUDO_USER}'. Do NOT do that:"
  fi
  err "root-owned state/.terraform/caches will break later runs as your normal user."
  if [ "$ASSUME_YES" = "1" ]; then
    err "Refusing to continue as root in non-interactive mode. Re-run as a normal user."
    exit 1
  fi
  printf '%sType EXACTLY "I understand the risks" to continue as root: %s' "$C_BOLD" "$C_RESET" >&2
  local reply; IFS= read -r reply || true
  [ "$reply" = "I understand the risks" ] || { err "Aborting. Re-run as a normal user."; exit 1; }
  warn "Continuing as root at your request."
}

# --- Shell into a target's Makefile ----------------------------------------
run_make() { # run_make <local|cloud> <destroy|reset>   (streams live)
  local dir; if [ "$1" = "local" ]; then dir="$LOCAL_DIR"; else dir="$CLOUD_DIR"; fi
  ( cd "$dir" && make "$2" )
}

# --- Local existence -------------------------------------------------------
local_exists() {
  [ -f "${LOCAL_DIR}/terraform/terraform.tfstate" ] || return 1
  local n; n="$( (cd "${LOCAL_DIR}/terraform" && terraform state list 2>/dev/null | wc -l) || echo 0)"
  [ "${n:-0}" -gt 0 ] 2>/dev/null
}

# --- Cloud token + existence ----------------------------------------------
CLOUD_TOKEN_REASON=""
hcloud_valid() { # arg: token -> 0 valid; sets CLOUD_TOKEN_REASON on failure
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $1" "${HCLOUD_API}/ssh_keys" 2>/dev/null || echo 000)"
  case "$code" in
    200) return 0 ;;
    401) CLOUD_TOKEN_REASON="invalid or expired (HTTP 401)"; return 1 ;;
    000) CLOUD_TOKEN_REASON="cannot reach api.hetzner.cloud (network/proxy?)"; return 1 ;;
    *)   CLOUD_TOKEN_REASON="unexpected HTTP ${code}"; return 1 ;;
  esac
}

load_token_from_env_file() {
  [ -n "${HCLOUD_TOKEN:-}" ] && return 0
  [ -f "${CLOUD_DIR}/.env" ] || return 1
  local first
  first="$(grep -v '^[[:space:]]*#' "${CLOUD_DIR}/.env" | grep -v '^[[:space:]]*$' | head -1 || true)"
  case "$first" in HCLOUD_TOKEN=*) HCLOUD_TOKEN="${first#HCLOUD_TOKEN=}" ;; *) HCLOUD_TOKEN="$first" ;; esac
  HCLOUD_TOKEN="${HCLOUD_TOKEN%\"}"; HCLOUD_TOKEN="${HCLOUD_TOKEN#\"}"
  [ -n "${HCLOUD_TOKEN:-}" ]
}

ensure_token() { # interactive: guarantee a valid HCLOUD_TOKEN in the env
  if load_token_from_env_file; then
    if hcloud_valid "$HCLOUD_TOKEN"; then export HCLOUD_TOKEN; ok "Using a valid Hetzner token from the environment/.env."; return 0
    else warn "The token found in the environment/.env is ${CLOUD_TOKEN_REASON}."; fi
  fi
  warn "A valid Hetzner API token is required to tear the cloud server down."
  local tok=""
  while :; do
    printf '%sPaste your Hetzner API token (input hidden): %s' "$C_BOLD" "$C_RESET" >&2
    IFS= read -rs tok || true; printf '\n' >&2
    [ -n "$tok" ] || { warn "Empty token; try again (or Ctrl-C to quit)."; continue; }
    if hcloud_valid "$tok"; then ok "Token validated."; break
    else err "Token rejected: ${CLOUD_TOKEN_REASON}. Try again."; fi
  done
  HCLOUD_TOKEN="$tok"; export HCLOUD_TOKEN
}

cloud_server_count() {
  [ -n "${HCLOUD_TOKEN:-}" ] || { echo 0; return; }
  curl -s -H "Authorization: Bearer $HCLOUD_TOKEN" "${HCLOUD_API}/servers" 2>/dev/null \
    | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("meta",{}).get("pagination",{}).get("total_entries",0))
except Exception: print(0)' 2>/dev/null || echo 0
}
cloud_exists() { [ "$(cloud_server_count)" -gt 0 ] 2>/dev/null; }

confirm_generic() { # confirm_generic "message"  -> 0 to proceed
  [ "$ASSUME_YES" = "1" ] && return 0
  printf '%s%s [y/N]: %s' "$C_BOLD" "$1" "$C_RESET" >&2
  local s; IFS= read -r s || true
  case "$(lower "${s:-}")" in y|yes) return 0 ;; *) return 1 ;; esac
}

ask_purge() { # -> echoes "reset" or "destroy" based on the flag / a prompt
  if [ "$PURGE" = "1" ]; then echo "reset"; return; fi
  if [ "$ASSUME_YES" = "1" ]; then echo "destroy"; return; fi
  printf '%sAlso purge generated certs/secrets/inventory for a true cold start? [y/N]: %s' "$C_BOLD" "$C_RESET" >&2
  local s; IFS= read -r s || true
  case "$(lower "${s:-}")" in y|yes) echo "reset" ;; *) echo "destroy" ;; esac
}

# --- Teardown a single target ----------------------------------------------
destroy_target() { # target
  local t="$1" action
  if [ "$t" = "cloud" ]; then
    ensure_token
    if ! cloud_exists; then
      info "No running server found in the Hetzner project."
      confirm_generic "Run the cloud teardown anyway (sweeps leftovers and proves the project is empty)?" \
        || { info "Nothing done."; return 0; }
    fi
    warn "This deletes the Hetzner server AND its Primary IP, then proves the project is empty."
  else
    if ! local_exists; then
      info "No local deployment detected in Terraform state."
      confirm_generic "Run the local teardown anyway (sweeps any leftover containers/volumes)?" \
        || { info "Nothing done."; return 0; }
    fi
    warn "This removes the local containers, network and named volumes (data is deleted)."
  fi

  action="$(ask_purge)"
  confirm_generic "Proceed with '${t}' ${action} now?" || { info "Cancelled; nothing was torn down."; return 0; }

  hr
  run_make "$t" "$action"
  hr
  ok "'${t}' ${action} complete."
}

# --- Interactive chooser ---------------------------------------------------
welcome() {
  hr
  printf '%s  ELK over HTTPS - teardown launcher%s\n' "$C_BOLD" "$C_RESET"
  hr
  cat >&2 <<'EOF'
This tears down a deployment created by ./run.sh (or 'make deploy').
Local removes the containers, network and volumes.
Cloud deletes the Hetzner server and its Primary IP, then proves the project is empty.
EOF
}

choose_and_run() {
  local local_state cloud_hint
  local_state="not deployed"; local_exists && local_state="deployed"
  cloud_hint="needs a token to check"
  cat >&2 <<EOF

  ${C_BOLD}What do you want to tear down?${C_RESET}
    1) Local     Docker on this machine.      (${local_state})
    2) Cloud     The Hetzner VM.              (${cloud_hint})
    q) Quit
EOF
  printf 'Choice [q]: ' >&2
  local c; IFS= read -r c || true; c="${c:-q}"
  case "$c" in
    1) destroy_target local ;;
    2) destroy_target cloud ;;
    q|Q) info "Nothing torn down. Bye."; exit 0 ;;
    *) warn "Please choose 1, 2, or q."; choose_and_run ;;
  esac
}

# ============================ ARG PARSING ==================================
TARGET=""; PURGE=0; ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="$(lower "${2:-}")"; shift 2 ;;
    --purge|--purge-generated) PURGE=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) err "Unknown option: $1"; usage; exit 2 ;;
  esac
done

# ============================ NON-INTERACTIVE ==============================
if [ -n "$TARGET" ]; then
  case "$TARGET" in local|cloud) : ;; *) err "--target must be local or cloud"; exit 2 ;; esac
  check_not_root
  if [ "$TARGET" = "cloud" ]; then
    load_token_from_env_file || true
    [ -n "${HCLOUD_TOKEN:-}" ] || { err "Cloud teardown needs HCLOUD_TOKEN (env or cloud/.env)."; exit 1; }
    export HCLOUD_TOKEN
    hcloud_valid "$HCLOUD_TOKEN" || { err "Token invalid: ${CLOUD_TOKEN_REASON}"; exit 1; }
  fi
  ACTION="destroy"; [ "$PURGE" = "1" ] && ACTION="reset"
  run_make "$TARGET" "$ACTION"
  exit 0
fi

# ============================== INTERACTIVE ================================
welcome
check_not_root
choose_and_run
