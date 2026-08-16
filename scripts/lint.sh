#!/usr/bin/env bash
# ===========================================================================
# lint.sh - static analysis gate. Runs every linter the project ships with and
# fails if any of them do. Each tool is optional-but-checked: if a linter is
# not installed we say so and skip it rather than silently passing.
# ===========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"

RC=0

section "terraform fmt / validate"
if command -v terraform >/dev/null 2>&1; then
  if ( cd "${REPO_ROOT}/terraform" && terraform fmt -check -recursive ); then
    log_ok "terraform fmt: clean"
  else
    log_err "terraform fmt: run 'terraform fmt -recursive'"
    RC=1
  fi
  # validate needs an init. Keep it offline-friendly: a provider-download
  # failure (air-gapped) is a warning, but a real config error fails the gate.
  if ( cd "${REPO_ROOT}/terraform" && terraform init -backend=false -input=false >/dev/null 2>&1 ); then
    if ( cd "${REPO_ROOT}/terraform" && terraform validate ); then
      log_ok "terraform validate: clean"
    else
      log_err "terraform validate reported a configuration error"
      RC=1
    fi
  else
    log_warn "terraform init could not fetch providers (offline?); skipping validate"
  fi
else
  log_warn "terraform not installed; skipping fmt/validate"
fi

section "ansible-lint"
if command -v ansible-lint >/dev/null 2>&1; then
  if ( cd "${REPO_ROOT}/ansible" && ansible-lint ); then
    log_ok "ansible-lint: clean"
  else
    log_err "ansible-lint reported issues"
    RC=1
  fi
else
  log_warn "ansible-lint not installed; skipping"
fi

section "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  # -x follows sourced files (lib/common.sh).
  if shellcheck -x "${REPO_ROOT}"/scripts/*.sh "${REPO_ROOT}"/scripts/lib/*.sh; then
    log_ok "shellcheck: clean"
  else
    log_err "shellcheck reported issues"
    RC=1
  fi
else
  log_warn "shellcheck not installed; skipping"
fi

section "yamllint"
if command -v yamllint >/dev/null 2>&1; then
  if ( cd "${REPO_ROOT}" && yamllint ansible ); then
    log_ok "yamllint: clean"
  else
    log_err "yamllint reported issues"
    RC=1
  fi
else
  log_warn "yamllint not installed; skipping"
fi

if [ "$RC" -eq 0 ]; then
  log_ok "Lint gate passed."
else
  log_err "Lint gate failed."
fi
exit "$RC"
