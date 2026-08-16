#!/usr/bin/env bash
# ===========================================================================
# logs.sh (cloud) - tail recent service logs from the server over SSH.
# ===========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"

ADMIN_USER="$(read_tfvar admin_user deploy)"
SSH_KEY="$(read_tfvar ssh_private_key_path "${HOME}/.ssh/id_ed25519")"; SSH_KEY="${SSH_KEY/#\~/$HOME}"
KNOWN_HOSTS="${ANS_DIR}/.ssh_known_hosts"

IP="$( (cd "$TF_DIR" && terraform output -raw server_ipv4 2>/dev/null) || true )"
[ -n "$IP" ] || die "No server IP found (is it deployed?)."

ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$KNOWN_HOSTS" -i "$SSH_KEY" "${ADMIN_USER}@${IP}" \
    'sudo journalctl -u elasticsearch -u kibana -u nginx --no-pager -n 60'
