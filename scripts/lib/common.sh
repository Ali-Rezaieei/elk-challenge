#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Shared helpers: colour handling, logging, repo paths, small utilities.
# Sourced by the other scripts. Colour is emitted only when stdout is a TTY and
# NO_COLOR is unset, so piped/CI output stays clean.
# ---------------------------------------------------------------------------

# Resolve the repository root from this file's location, so every script works
# regardless of the caller's current directory.
_common_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${_common_dir}/../.." && pwd)"
export REPO_ROOT

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && command -v tput >/dev/null 2>&1 \
  && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  C_RED="$(tput setaf 1)"; C_GREEN="$(tput setaf 2)"; C_YELLOW="$(tput setaf 3)"
  C_BLUE="$(tput setaf 4)"; C_BOLD="$(tput bold)"; C_RESET="$(tput sgr0)"
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""; C_RESET=""
fi

# Structured logging to stderr so it never pollutes captured stdout.
log_info() { printf '%s[*]%s %s\n' "$C_BLUE" "$C_RESET" "$*" >&2; }
log_ok()   { printf '%s[+]%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
log_warn() { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_err()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

# A visible section banner.
section() {
  printf '\n%s== %s ==%s\n' "$C_BOLD" "$*" "$C_RESET" >&2
}

# die MESSAGE [EXIT_CODE]
die() {
  log_err "${1:-unexpected error}"
  exit "${2:-1}"
}

# Detect the platform once; other scripts read these exported values.
detect_platform() {
  PLATFORM_KERNEL="$(uname -s)"
  PLATFORM_ARCH="$(uname -m)"
  IS_WSL="false"
  if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then IS_WSL="true"; fi
  export PLATFORM_KERNEL PLATFORM_ARCH IS_WSL
}
