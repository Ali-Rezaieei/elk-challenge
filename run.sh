#!/usr/bin/env bash
# ===========================================================================
# run.sh - the single interactive entry point for DEPLOYING this repository.
#
# It ORCHESTRATES only: every real step lives in local/ or cloud/, and each is
# treated as a black box (its own Makefile + scripts). The experience is
# identical for both targets: welcome -> choose -> confirm -> preflight ->
# deploy (streamed) -> result -> menu.
#
# Teardown is deliberately NOT here. Destroying a deployment is a separate,
# explicit action: use ./destroy.sh (so a stack is never torn down by hitting
# the wrong menu item mid-session).
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

# --- Interrupt handling -----------------------------------------------------
CURRENT_TARGET=""
CLOUD_OP_ACTIVE=0
on_interrupt() {
  printf '\n'
  warn "Interrupted."
  if [ "$CURRENT_TARGET" = "cloud" ] && [ "$CLOUD_OP_ACTIVE" = "1" ]; then
    warn "A cloud deploy was in progress. It auto-cleans on abort, but confirm nothing"
    warn "is still billing by running the teardown launcher:"
    printf '    ./destroy.sh   ->  Cloud\n' >&2
  fi
  exit 130
}
trap on_interrupt INT TERM

usage() {
  cat <<EOF
Usage: ./run.sh [options]

Interactive (no options): guides you through deploying locally or to the cloud.

Non-interactive:
  ./run.sh --target <local|cloud> --action <deploy|verify> [--yes]

Options:
  --target   local | cloud
  --action   deploy | verify
  --yes      assume yes / skip confirmations (required for non-interactive cloud spend)
  --help     show this help

Examples:
  ./run.sh
  ./run.sh --target local  --action deploy --yes
  ./run.sh --target cloud  --action verify

To tear a deployment down, use ./destroy.sh.
EOF
}

# --- Rule 2: do not run as root --------------------------------------------
# Running as root leaves root-owned Terraform state / .terraform / Ansible
# caches that then fail for the normal user. Genuine per-command root (e.g.
# sysctl) is requested by the sub-scripts with a single sudo, explained inline.
check_not_root() {
  local uid; uid="$(id -u)"
  [ "$uid" -ne 0 ] && return 0
  err "run.sh is running as root (uid 0)."
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

# --- Small helpers over the two black boxes --------------------------------
run_make() { # run_make <local|cloud> <action>   (streams live)
  local dir; if [ "$1" = "local" ]; then dir="$LOCAL_DIR"; else dir="$CLOUD_DIR"; fi
  ( cd "$dir" && make "$2" )
}

target_url() { # echo the https URL from terraform state, best-effort
  local dir; if [ "$1" = "local" ]; then dir="$LOCAL_DIR"; else dir="$CLOUD_DIR"; fi
  ( cd "${dir}/terraform" && terraform output -raw https_url 2>/dev/null ) || true
}

target_password() { # echo the generated elastic password, best-effort
  local dir; if [ "$1" = "local" ]; then dir="$LOCAL_DIR"; else dir="$CLOUD_DIR"; fi
  local f="${dir}/ansible/.secrets/elastic_password"
  if [ -f "$f" ]; then cat "$f"; fi
}

open_browser() {
  local url="$1"
  if command -v xdg-open >/dev/null 2>&1; then xdg-open "$url" >/dev/null 2>&1 &
  elif command -v open >/dev/null 2>&1; then open "$url" >/dev/null 2>&1 &
  else warn "No browser opener found. Open this URL manually: ${url}"; fi
}

show_credentials() { # target
  local url pw
  url="$(target_url "$1")"; pw="$(target_password "$1")"
  hr
  printf '  URL:      %s\n' "${url:-unknown}"
  printf '  Username: elastic\n'
  printf '  Password: %s\n' "${pw:-<not found - is it deployed?>}"
  [ "$1" = "cloud" ] && printf '  %sThis server bills until you destroy it (./destroy.sh).%s\n' "$C_BOLD" "$C_RESET"
  hr
}

# --- Local existence + flow ------------------------------------------------
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
  cat >&2 <<'EOF'

To create a Hetzner Cloud API token:
  1. Open https://console.hetzner.cloud/ and sign in.
  2. Create (or open) a project.
  3. Left sidebar: Security -> API tokens.
  4. "Generate API token", give it a name, choose "Read & Write".
  5. Copy the token now (it is shown only once).

EOF
  local tok=""
  while :; do
    printf '%sPaste your Hetzner API token (input hidden): %s' "$C_BOLD" "$C_RESET" >&2
    IFS= read -rs tok || true; printf '\n' >&2
    [ -n "$tok" ] || { warn "Empty token; try again (or Ctrl-C to quit)."; continue; }
    if hcloud_valid "$tok"; then ok "Token validated."; break
    else err "Token rejected: ${CLOUD_TOKEN_REASON}. Try again."; fi
  done
  HCLOUD_TOKEN="$tok"; export HCLOUD_TOKEN
  printf 'Save this token to %s for reuse (gitignored)? [y/N]: ' "${CLOUD_DIR}/.env" >&2
  local s; IFS= read -r s || true
  case "$(lower "${s:-}")" in
    y|yes) printf 'HCLOUD_TOKEN=%s\n' "$HCLOUD_TOKEN" > "${CLOUD_DIR}/.env"; chmod 600 "${CLOUD_DIR}/.env"; ok "Saved to ${CLOUD_DIR}/.env (chmod 600)." ;;
    *) info "Not saved. It stays only in this shell session." ;;
  esac
}

cloud_server_count() {
  [ -n "${HCLOUD_TOKEN:-}" ] || { echo 0; return; }
  curl -s -H "Authorization: Bearer $HCLOUD_TOKEN" "${HCLOUD_API}/servers" 2>/dev/null \
    | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("meta",{}).get("pagination",{}).get("total_entries",0))
except Exception: print(0)' 2>/dev/null || echo 0
}
cloud_exists() { [ "$(cloud_server_count)" -gt 0 ] 2>/dev/null; }

ensure_ssh_key() {
  local pub="${HOME}/.ssh/id_ed25519.pub" key="${HOME}/.ssh/id_ed25519"
  [ -f "$pub" ] && { ok "SSH key present (${pub})."; return 0; }
  warn "No SSH key at ${pub}."
  printf 'Generate one now with: %sssh-keygen -t ed25519 -f %s -N ""%s ? [y/N]: ' "$C_BOLD" "$key" "$C_RESET" >&2
  local s; IFS= read -r s || true
  case "$(lower "${s:-}")" in
    y|yes) ssh-keygen -t ed25519 -f "$key" -N "" && ok "Generated ${key}." ;;
    *) err "An SSH key is required for the cloud path. Create one and re-run."; return 1 ;;
  esac
}

confirm_cost() {
  cat >&2 <<EOF

${C_BOLD}About to create a real Hetzner server (cx33, 8 GB).${C_RESET}
  - Cost is roughly EUR 0.02-0.03 per hour, including a Primary IPv4.
  - A deploy + short test + destroy cycle costs only a few cents.
  - It will keep billing until you tear it down with ./destroy.sh.
EOF
  if [ "$ASSUME_YES" = "1" ]; then ok "Proceeding (--yes)."; return 0; fi
  printf '%sType "yes" to create it and start spending: %s' "$C_BOLD" "$C_RESET" >&2
  local s; IFS= read -r s || true
  [ "$(lower "${s:-}")" = "yes" ] || { info "Not confirmed; nothing was created."; return 1; }
}

confirm_generic() { # confirm_generic "message"  -> 0 to proceed
  [ "$ASSUME_YES" = "1" ] && return 0
  printf '%s%s [Y/n]: %s' "$C_BOLD" "$1" "$C_RESET" >&2
  local s; IFS= read -r s || true
  case "$(lower "${s:-}")" in n|no) return 1 ;; *) return 0 ;; esac
}

result_block() { # target
  local url pw ip
  url="$(target_url "$1")"; pw="$(target_password "$1")"
  hr
  ok "Deployment complete."
  printf '  URL:       %s\n' "${url:-unknown}"
  printf '  Username:  elastic\n'
  printf '  Password:  %s\n' "${pw:-<not found>}"
  printf '\n  Your browser will warn about the certificate. That is expected -\n'
  printf '  it is signed by a CA created at deploy time.\n'
  if [ "$1" = "cloud" ]; then
    ip="$( (cd "${CLOUD_DIR}/terraform" && terraform output -raw server_ipv4 2>/dev/null) || true )"
    printf '\n  Public IP: %s\n' "${ip:-unknown}"
    printf '  %sThis server costs money until you tear it down.%s\n' "$C_BOLD" "$C_RESET"
  fi
  printf '  To tear down:  ./destroy.sh\n'
  hr
}

# --- Post-deploy / existing-deployment menu --------------------------------
# Read-only actions only. Teardown lives in ./destroy.sh, on purpose.
post_menu() { # target
  local t="$1"
  while :; do
    cat >&2 <<EOF

  ${C_BOLD}What next?${C_RESET}
    1) Open in browser
    2) Re-run verification
    3) Show credentials
    4) Show logs
    q) Leave running and exit
EOF
    printf 'Choice [q]: ' >&2
    local c; IFS= read -r c || true; c="${c:-q}"
    case "$c" in
      1) open_browser "$(target_url "$t")" ;;
      2) run_make "$t" verify || warn "Verification reported problems (see above)." ;;
      3) show_credentials "$t" ;;
      4) run_make "$t" logs || warn "Could not fetch logs." ;;
      q|Q)
        if [ "$t" = "cloud" ] && cloud_exists; then
          warn "The cloud server is STILL RUNNING and still billing."
          warn "Tear it down with:  ./destroy.sh  ->  Cloud"
        else
          info "Left running. Tear it down anytime with ./destroy.sh."
        fi
        return 0 ;;
      *) warn "Please choose 1-4 or q." ;;
    esac
  done
}

deploy_target() { # target - run the deploy and show the result + menu
  local t="$1"
  CURRENT_TARGET="$t"
  [ "$t" = "cloud" ] && CLOUD_OP_ACTIVE=1
  if run_make "$t" deploy; then
    [ "$t" = "cloud" ] && CLOUD_OP_ACTIVE=0
    result_block "$t"
    post_menu "$t"
  else
    [ "$t" = "cloud" ] && CLOUD_OP_ACTIVE=0
    err "Deploy did not complete. The output above explains what failed and how to fix it."
    if [ "$t" = "cloud" ]; then
      err "The cloud deploy auto-cleans on failure; confirm no server remains: ./destroy.sh -> Cloud"
    fi
    return 1
  fi
}

interactive_local() {
  CURRENT_TARGET="local"
  if local_exists; then
    warn "An existing local deployment was detected."
    info "To tear it down (or before redeploying), run ./destroy.sh first."
    post_menu local
    return 0
  fi
  confirm_generic "Build the stack locally with Docker (~3-6 min on first run). Continue?" || { info "Cancelled."; return 0; }
  deploy_target local
}

interactive_cloud() {
  CURRENT_TARGET="cloud"
  ensure_token
  if cloud_exists; then
    warn "An existing cloud deployment was detected."
    info "To tear it down (or before redeploying), run ./destroy.sh first."
    post_menu cloud
    return 0
  fi
  ensure_ssh_key || return 1
  confirm_cost || return 0
  deploy_target cloud
}

welcome() {
  hr
  printf '%s  ELK over HTTPS - one launcher for local and cloud%s\n' "$C_BOLD" "$C_RESET"
  hr
  cat >&2 <<'EOF'
This deploys a single-node Elasticsearch + Kibana stack behind an nginx TLS edge.
Terraform builds the infrastructure; Ansible configures the services.
Everything is reachable only over HTTPS.

When you are done, tear it down with ./destroy.sh.
EOF
}

choose_and_run() {
  cat >&2 <<EOF

  ${C_BOLD}Where do you want to deploy?${C_RESET}
    1) Local     Docker on this machine. No account, no cost. ~5 minutes.
    2) Cloud     A Hetzner VM with a real firewall.
                 Needs a Hetzner account and API token. ~EUR 0.03/hour.
    q) Quit
EOF
  printf 'Choice [1]: ' >&2
  local c; IFS= read -r c || true; c="${c:-1}"
  case "$c" in
    1) interactive_local ;;
    2) interactive_cloud ;;
    q|Q) info "Bye."; exit 0 ;;
    *) warn "Please choose 1, 2, or q."; choose_and_run ;;
  esac
}

# ============================ ARG PARSING ==================================
TARGET=""; ACTION=""; ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="$(lower "${2:-}")"; shift 2 ;;
    --action) ACTION="$(lower "${2:-}")"; shift 2 ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) err "Unknown option: $1"; usage; exit 2 ;;
  esac
done

# ============================ NON-INTERACTIVE ==============================
if [ -n "$TARGET" ] || [ -n "$ACTION" ]; then
  if [ -z "$TARGET" ] || [ -z "$ACTION" ]; then err "Both --target and --action are required for non-interactive mode."; usage; exit 2; fi
  case "$TARGET" in local|cloud) : ;; *) err "--target must be local or cloud"; exit 2 ;; esac
  case "$ACTION" in
    deploy|verify) : ;;
    destroy) err "Teardown moved out of run.sh. Use: ./destroy.sh --target ${TARGET} [--purge] [--yes]"; exit 2 ;;
    *) err "--action must be deploy or verify"; exit 2 ;;
  esac
  check_not_root
  CURRENT_TARGET="$TARGET"
  if [ "$TARGET" = "cloud" ]; then
    load_token_from_env_file || true
    [ -n "${HCLOUD_TOKEN:-}" ] || { err "Cloud action needs HCLOUD_TOKEN (env or cloud/.env)."; exit 1; }
    export HCLOUD_TOKEN
    hcloud_valid "$HCLOUD_TOKEN" || { err "Token invalid: ${CLOUD_TOKEN_REASON}"; exit 1; }
    [ "$ACTION" = "deploy" ] && CLOUD_OP_ACTIVE=1
  fi
  run_make "$TARGET" "$ACTION"
  CLOUD_OP_ACTIVE=0
  exit 0
fi

# ============================== INTERACTIVE ================================
welcome
check_not_root
choose_and_run
