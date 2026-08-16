#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Shared helpers for the CLOUD side only (self-contained; not shared with
# local/). Colour handling, logging, repo paths, token loading, and thin
# Hetzner Cloud API wrappers. JSON is parsed with python3 (always present; no
# jq dependency). Sourced by the other scripts.
# ---------------------------------------------------------------------------

# Resolve cloud/ (the project root of this side) from this file's location.
_common_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${_common_dir}/../.." && pwd)"
export REPO_ROOT
TF_DIR="${REPO_ROOT}/terraform"
ANS_DIR="${REPO_ROOT}/ansible"
export TF_DIR ANS_DIR

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && command -v tput >/dev/null 2>&1 \
  && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  C_RED="$(tput setaf 1)"; C_GREEN="$(tput setaf 2)"; C_YELLOW="$(tput setaf 3)"
  C_BLUE="$(tput setaf 4)"; C_BOLD="$(tput bold)"; C_RESET="$(tput sgr0)"
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""; C_RESET=""
fi

log_info() { printf '%s[*]%s %s\n' "$C_BLUE" "$C_RESET" "$*" >&2; }
log_ok()   { printf '%s[+]%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
log_warn() { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_err()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
section()  { printf '\n%s== %s ==%s\n' "$C_BOLD" "$*" "$C_RESET" >&2; }
die()      { log_err "${1:-unexpected error}"; exit "${2:-1}"; }

# ---------------------------------------------------------------------------
# Token loading. Order of precedence: existing HCLOUD_TOKEN env, then the
# gitignored cloud/.env (accepts either `HCLOUD_TOKEN=<t>` or a bare token on
# the first line). The token is NEVER echoed. TF_VAR_hcloud_token is exported
# so Terraform picks it up without it ever being written to disk by us.
# ---------------------------------------------------------------------------
load_hcloud_token() {
  if [ -z "${HCLOUD_TOKEN:-}" ] && [ -f "${REPO_ROOT}/.env" ]; then
    local first
    first="$(grep -v '^[[:space:]]*#' "${REPO_ROOT}/.env" | grep -v '^[[:space:]]*$' | head -1 || true)"
    case "$first" in
      HCLOUD_TOKEN=*) HCLOUD_TOKEN="${first#HCLOUD_TOKEN=}" ;;
      *)              HCLOUD_TOKEN="$first" ;;
    esac
    # Strip optional surrounding quotes.
    HCLOUD_TOKEN="${HCLOUD_TOKEN%\"}"; HCLOUD_TOKEN="${HCLOUD_TOKEN#\"}"
    HCLOUD_TOKEN="${HCLOUD_TOKEN%\'}"; HCLOUD_TOKEN="${HCLOUD_TOKEN#\'}"
  fi
  export HCLOUD_TOKEN
  [ -n "${HCLOUD_TOKEN:-}" ] && export TF_VAR_hcloud_token="${HCLOUD_TOKEN}"
}

# ---------------------------------------------------------------------------
# Hetzner Cloud API (v1). All calls are authenticated with the bearer token.
# ---------------------------------------------------------------------------
HCLOUD_API="${HCLOUD_API:-https://api.hetzner.cloud/v1}"

hc_get()        { curl -fsS       -H "Authorization: Bearer ${HCLOUD_TOKEN}" "${HCLOUD_API}$1" 2>/dev/null; }
hc_get_code()   { curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${HCLOUD_TOKEN}" "${HCLOUD_API}$1" 2>/dev/null; }
hc_post_code()  { curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer ${HCLOUD_TOKEN}" -H 'Content-Type: application/json' -d "${2:-{}}" "${HCLOUD_API}$1" 2>/dev/null; }
hc_delete_code(){ curl -s -o /dev/null -w '%{http_code}' -X DELETE -H "Authorization: Bearer ${HCLOUD_TOKEN}" "${HCLOUD_API}$1" 2>/dev/null; }

# Number of entries in a list endpoint (uses meta.pagination.total_entries).
# Usage: hc_count /servers servers
hc_count() {
  hc_get "$1" 2>/dev/null | python3 -c "import sys,json
try:
    d=json.load(sys.stdin)
except Exception:
    print(-1); sys.exit(0)
print(d.get('meta',{}).get('pagination',{}).get('total_entries', len(d.get('$2',[]))))" 2>/dev/null || echo -1
}

# Newline-separated top-level ids from a list endpoint.
# Usage: hc_ids /primary_ips primary_ips
hc_ids() {
  hc_get "$1" 2>/dev/null | python3 -c "import sys,json
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
print('\n'.join(str(x.get('id')) for x in d.get('$2',[])))" 2>/dev/null || true
}

# Newline-separated "name" values from a list endpoint.
hc_names() {
  hc_get "$1" 2>/dev/null | python3 -c "import sys,json
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
print('\n'.join(str(x.get('name', x.get('ip','?'))) for x in d.get('$2',[])))" 2>/dev/null || true
}

# Read a Terraform variable default/override from terraform.tfvars if present.
read_tfvar() { # read_tfvar NAME DEFAULT
  local name="$1" def="$2" val="" f="${TF_DIR}/terraform.tfvars"
  if [ -f "$f" ]; then
    val="$(grep -E "^[[:space:]]*${name}[[:space:]]*=" "$f" 2>/dev/null \
      | head -1 | sed -E 's/[^=]*=[[:space:]]*//; s/[",]//g; s/[[:space:]]*$//' || true)"
  fi
  printf '%s' "${val:-$def}"
}
