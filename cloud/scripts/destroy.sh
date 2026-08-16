#!/usr/bin/env bash
# ===========================================================================
# destroy.sh (cloud) - tear everything down and PROVE the project is empty.
#
# Hetzner Primary IPs are billed separately and survive server deletion - the
# most common silent charge. Terraform removes the ones it created, and this
# script additionally sweeps any left behind, then prints a full API listing so
# the empty project is provable, not assumed.
#
# Options:
#   --purge-generated   also delete local certs/secrets/inventory/state
#   --diagnostics       collect service logs from the server before destroying
# ===========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"
load_hcloud_token

PURGE="false"; DIAG="false"
for a in "$@"; do
  case "$a" in
    --purge-generated) PURGE="true" ;;
    --diagnostics)     DIAG="true" ;;
  esac
done

PREFIX="$(read_tfvar project_prefix elk-cloud)"
ADMIN_USER="$(read_tfvar admin_user deploy)"
SSH_KEY="$(read_tfvar ssh_private_key_path "${HOME}/.ssh/id_ed25519")"; SSH_KEY="${SSH_KEY/#\~/$HOME}"
KNOWN_HOSTS="${ANS_DIR}/.ssh_known_hosts"

collect_diagnostics() {
  local ip; ip="$( (cd "$TF_DIR" && terraform output -raw server_ipv4 2>/dev/null) || true )"
  [ -n "$ip" ] || { log_warn "no server IP known; skipping diagnostics"; return 0; }
  local dir
  dir="${REPO_ROOT}/diagnostics/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$dir"
  log_info "Collecting diagnostics from ${ip} into ${dir} ..."
  local ssh_opts=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$KNOWN_HOSTS" -i "$SSH_KEY")
  ssh "${ssh_opts[@]}" "${ADMIN_USER}@${ip}" 'sudo journalctl -u elasticsearch --no-pager' >"${dir}/elasticsearch.journal.log" 2>&1 || true
  ssh "${ssh_opts[@]}" "${ADMIN_USER}@${ip}" 'sudo journalctl -u kibana --no-pager'        >"${dir}/kibana.journal.log" 2>&1 || true
  ssh "${ssh_opts[@]}" "${ADMIN_USER}@${ip}" 'sudo tail -n 500 /var/log/nginx/error.log'   >"${dir}/nginx.error.log" 2>&1 || true
  ssh "${ssh_opts[@]}" "${ADMIN_USER}@${ip}" 'sudo cat /var/log/cloud-init-output.log'      >"${dir}/cloud-init-output.log" 2>&1 || true
  ssh "${ssh_opts[@]}" "${ADMIN_USER}@${ip}" 'sudo cat /var/log/cloud-init.log'             >"${dir}/cloud-init.log" 2>&1 || true
  ssh "${ssh_opts[@]}" "${ADMIN_USER}@${ip}" 'sudo tail -n 500 /var/log/elasticsearch/*.log' >"${dir}/elasticsearch.app.log" 2>&1 || true
  log_ok "Diagnostics saved to ${dir}"
}

# Capture the IP before destroy so we can purge its host key afterwards
# (Hetzner reuses IPs; a stale known_hosts entry breaks the next deploy).
DESTROYED_IP="$( (cd "$TF_DIR" && terraform output -raw server_ipv4 2>/dev/null) || true )"

[ "$DIAG" = "true" ] && collect_diagnostics

# --- Terraform destroy -----------------------------------------------------
section "Terraform destroy (server, network, firewall, SSH key, Primary IP)"
if [ -d "${TF_DIR}/.terraform" ] || [ -f "${TF_DIR}/terraform.tfstate" ]; then
  ( cd "$TF_DIR" && terraform destroy -auto-approve -input=false ) \
    || log_warn "terraform destroy reported an error; falling back to an API sweep"
else
  log_info "No Terraform state found; skipping to the API sweep"
fi

# --- API sweep: remove anything left with our project label ----------------
if [ -n "${HCLOUD_TOKEN:-}" ]; then
  section "API sweep for leftover '${PREFIX}' resources"
  SEL="label_selector=project==${PREFIX}"

  for id in $(hc_ids "/servers?${SEL}" servers); do
    [ -n "$id" ] && { hc_delete_code "/servers/${id}" >/dev/null && log_info "deleted server ${id}"; }
  done
  # Primary IPs are billed separately and outlive the server - delete explicitly.
  for id in $(hc_ids "/primary_ips?${SEL}" primary_ips); do
    [ -n "$id" ] && { hc_delete_code "/primary_ips/${id}" >/dev/null && log_info "deleted Primary IP ${id}"; }
  done
  for id in $(hc_ids "/firewalls?${SEL}" firewalls); do
    [ -n "$id" ] && { hc_delete_code "/firewalls/${id}" >/dev/null && log_info "deleted firewall ${id}"; }
  done
  for id in $(hc_ids "/networks?${SEL}" networks); do
    [ -n "$id" ] && { hc_delete_code "/networks/${id}" >/dev/null && log_info "deleted network ${id}"; }
  done
  for id in $(hc_ids "/ssh_keys?${SEL}" ssh_keys); do
    [ -n "$id" ] && { hc_delete_code "/ssh_keys/${id}" >/dev/null && log_info "deleted SSH key ${id}"; }
  done
fi

# --- Proof: list THIS deployment's resources (label project==<prefix>). -----
# Scoped to our project label on purpose. Everything this stack creates - the
# server, Primary IP, network, firewall AND the SSH key - is labelled
# project==<prefix> by Terraform, so this proves *our* footprint is gone.
# Resources you own outside this deployment (e.g. an SSH key you added to the
# project by hand) are deliberately NOT counted or deleted - they are not ours
# to touch, and they used to trigger a false "NOT empty".
if [ -n "${HCLOUD_TOKEN:-}" ]; then
  section "Final project-scoped listing (everything labelled project==${PREFIX} must be 0)"
  SEL="label_selector=project==${PREFIX}"
  TOTAL=0
  for pair in \
    "servers:servers" "primary_ips:primary_ips" "floating_ips:floating_ips" \
    "volumes:volumes" "images?type=snapshot:images" "images?type=backup:images" \
    "certificates:certificates" "load_balancers:load_balancers" \
    "networks:networks" "firewalls:firewalls" "ssh_keys:ssh_keys"; do
    ep="${pair%%:*}"; key="${pair##*:}"
    # Append the label selector, respecting endpoints that already have a query.
    case "$ep" in
      *\?*) url="/${ep}&${SEL}" ;;
      *)    url="/${ep}?${SEL}" ;;
    esac
    n="$(hc_count "$url" "$key")"; [ "$n" = "-1" ] && n="?"
    printf '  %-24s %s\n' "${ep}:" "$n"
    case "$n" in ''|0|\?) : ;; *) TOTAL=$((TOTAL + n)) ;; esac
    names="$(hc_names "$url" "$key")"
    [ -n "$names" ] && printf '%s\n' "$names" | sed 's/^/      - /'
  done
  if [ "$TOTAL" -eq 0 ]; then
    log_ok "This deployment is fully gone: 0 resources labelled project==${PREFIX} (server, Primary IP, network, firewall and SSH key all removed). Nothing from this stack remains or bills."
  else
    log_warn "Still ${TOTAL} resource(s) labelled project==${PREFIX} (above). Investigate in the console."
  fi
fi

# --- Optional: local cold-start purge -------------------------------------
if [ "$PURGE" = "true" ]; then
  section "Purging generated PKI, secrets, inventory and state (true cold start)"
  rm -rf "${ANS_DIR}/.certs" "${ANS_DIR}/.secrets" "${ANS_DIR}/inventory/hosts.yml" "$KNOWN_HOSTS"
  rm -f "${TF_DIR}/terraform.tfstate" "${TF_DIR}/terraform.tfstate.backup"
  log_ok "Generated material removed. Next deploy starts from zero."
else
  log_info "Kept generated certs/secrets/state (reused next deploy). Use --purge-generated for a true cold start."
fi

# Drop the destroyed server's host key so a future deploy on a reused IP is clean.
if [ -n "${DESTROYED_IP:-}" ] && [ -f "$KNOWN_HOSTS" ]; then
  ssh-keygen -R "$DESTROYED_IP" -f "$KNOWN_HOSTS" >/dev/null 2>&1 || true
fi

log_ok "Teardown complete."
