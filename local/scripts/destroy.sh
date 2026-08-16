#!/usr/bin/env bash
# ===========================================================================
# destroy.sh - tear the stack down, including named volumes (so data is really
# gone). With --purge-generated it also deletes the deploy-time PKI, secrets
# and the generated inventory, giving a genuine cold start ("make reset").
# ===========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"

PURGE="false"
[ "${1:-}" = "--purge-generated" ] && PURGE="true"

TF_DIR="${REPO_ROOT}/terraform"
ANS_DIR="${REPO_ROOT}/ansible"
PREFIX="$( { [ -f "${TF_DIR}/terraform.tfvars" ] && grep -E '^[[:space:]]*project_prefix' "${TF_DIR}/terraform.tfvars" | sed -E 's/[^=]*=[[:space:]]*//; s/[" ]//g'; } || true )"
PREFIX="${PREFIX:-elk-local}"

section "Terraform destroy (removes containers, network and named volumes)"
if [ -d "${TF_DIR}/.terraform" ] || [ -f "${TF_DIR}/terraform.tfstate" ]; then
  ( cd "$TF_DIR" && terraform destroy -auto-approve -input=false ) || \
    log_warn "terraform destroy reported an error; falling back to a docker-level sweep"
else
  log_info "No Terraform state found; skipping to docker-level sweep"
fi

# Belt-and-braces: remove anything left with our prefix, in case state drifted.
# Scoped strictly to the project prefix so we never touch unrelated objects.
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  section "Docker sweep for leftover '${PREFIX}-' objects"
  for c in $(docker ps -a --filter "name=${PREFIX}-" --format '{{.Names}}' 2>/dev/null); do
    if docker rm -f "$c" >/dev/null 2>&1; then log_info "removed container $c"; fi
  done
  for v in $(docker volume ls --filter "name=${PREFIX}-" --format '{{.Name}}' 2>/dev/null); do
    if docker volume rm "$v" >/dev/null 2>&1; then log_info "removed volume $v"; fi
  done
  if docker network ls --format '{{.Name}}' | grep -q "^${PREFIX}-net$"; then
    if docker network rm "${PREFIX}-net" >/dev/null 2>&1; then log_info "removed network ${PREFIX}-net"; fi
  fi
fi

if [ "$PURGE" = "true" ]; then
  section "Purging generated PKI, secrets and inventory (true cold start)"
  rm -rf "${ANS_DIR}/.certs" "${ANS_DIR}/.secrets" "${ANS_DIR}/inventory/hosts.yml"
  rm -f "${TF_DIR}/terraform.tfstate" "${TF_DIR}/terraform.tfstate.backup"
  log_ok "Generated material removed. Next 'make deploy' starts from zero."
else
  log_info "Kept generated certs/secrets (reused next deploy). Use 'make reset' to purge them."
fi

log_ok "Teardown complete."
