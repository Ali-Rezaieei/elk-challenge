#!/usr/bin/env bash
# ===========================================================================
# verify.sh (cloud) - functional + SECURITY smoke tests against the live
# server. A green apply and a green playbook prove nothing; this proves data
# actually flows and the posture actually holds. Exits non-zero on any failure.
# ===========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"

CA_CERT="${ANS_DIR}/.certs/ca.crt"
PW_FILE="${ANS_DIR}/.secrets/elastic_password"
ADMIN_USER="$(read_tfvar admin_user deploy)"
SSH_KEY="$(read_tfvar ssh_private_key_path "${HOME}/.ssh/id_ed25519")"; SSH_KEY="${SSH_KEY/#\~/$HOME}"
KNOWN_HOSTS="${ANS_DIR}/.ssh_known_hosts"

IP="$( (cd "$TF_DIR" && terraform output -raw server_ipv4 2>/dev/null) || true )"
if [ -z "$IP" ] && [ -f "${ANS_DIR}/inventory/hosts.yml" ]; then
  IP="$(grep -E 'ansible_host:' "${ANS_DIR}/inventory/hosts.yml" | head -1 | sed -E 's/.*"([0-9.]+)".*/\1/')"
fi
[ -n "$IP" ] || die "Could not determine the server IP (no terraform output, no inventory). Is it deployed?"
[ -f "$CA_CERT" ] || die "CA certificate not found at ${CA_CERT}; has the stack been deployed?"

BASE="https://${IP}"
ELASTIC_PW="$( [ -f "$PW_FILE" ] && cat "$PW_FILE" || echo "" )"

cca()  { curl --cacert "$CA_CERT" "$@"; }
sshx() { ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
             -o UserKnownHostsFile="$KNOWN_HOSTS" -i "$SSH_KEY" "${ADMIN_USER}@${IP}" "$@"; }
port_open() { timeout 6 bash -c "exec 3<>/dev/tcp/${IP}/$1" 2>/dev/null; }

PASS_COUNT=0; FAIL_COUNT=0
check() {
  local label="$1"; shift
  if "$@"; then PASS_COUNT=$((PASS_COUNT+1)); printf '  %s[PASS]%s %s\n' "$C_GREEN" "$C_RESET" "$label"
  else FAIL_COUNT=$((FAIL_COUNT+1)); printf '  %s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$label"; fi
}

section "Verifying ${BASE} (server ${IP})"

# 1. HTTPS responds AND the chain validates against the internal CA (SAN=IP).
t_https_valid() {
  local code; code="$(cca -s -o /dev/null -w '%{http_code}' "${BASE}/" 2>/dev/null || echo 000)"
  [ "$code" = "200" ] || [ "$code" = "302" ]
}
check "HTTPS edge responds and TLS validates against the internal CA" t_https_valid

# 2. Plain HTTP to the TLS port serves no content.
t_http_refused() {
  local code; code="$(curl -s -o /dev/null -w '%{http_code}' "http://${IP}:443/" 2>/dev/null || echo 000)"
  [ "$code" != "200" ]
}
check "Plain HTTP is refused (no cleartext content served)" t_http_refused

# 3. Elasticsearch cluster health via the proxy is green or yellow.
t_es_health() {
  cca -s -u "elastic:${ELASTIC_PW}" "${BASE}/es/_cluster/health" 2>/dev/null | grep -qE '"status":"(green|yellow)"'
}
check "Elasticsearch cluster health is green/yellow (via /es/)" t_es_health

# 4. Kibana status API reports 'available' (not 'degraded').
t_kibana_available() {
  cca -s "${BASE}/api/status" 2>/dev/null | grep -q '"level":"available"'
}
check "Kibana status API reports 'available'" t_kibana_available

# 5. Kibana returns a real login page (HTTP 200, real HTML) - not 502, not
#    "Kibana server is not ready yet".
t_kibana_login_html() {
  local out code body
  out="$(cca -s -L -w '\n%{http_code}' "${BASE}/login" 2>/dev/null || echo)"
  code="$(printf '%s' "$out" | tail -n1)"
  body="$(printf '%s' "$out" | sed '$d')"
  [ "$code" = "200" ] || return 1
  printf '%s' "$body" | grep -qi 'not ready' && return 1
  printf '%s' "$body" | grep -qiE 'kbn|elastic|loginForm|core\.entry'
}
check "Kibana serves a real login page (HTTP 200, not 'server not ready')" t_kibana_login_html

# 6. SECURITY: unauthenticated Elasticsearch request is rejected.
t_es_unauth_rejected() {
  local code; code="$(cca -s -o /dev/null -w '%{http_code}' "${BASE}/es/_security/_authenticate" 2>/dev/null || echo 000)"
  [ "$code" = "401" ] || [ "$code" = "403" ]
}
check "Unauthenticated Elasticsearch request is rejected (security is ON)" t_es_unauth_rejected

# 7. SECURITY: authenticated request succeeds.
t_es_auth_ok() {
  local code; code="$(cca -s -o /dev/null -w '%{http_code}' -u "elastic:${ELASTIC_PW}" "${BASE}/es/_security/_authenticate" 2>/dev/null || echo 000)"
  [ "$code" = "200" ]
}
check "Authenticated Elasticsearch request succeeds with generated credentials" t_es_auth_ok

# 8. FULL ROUND TRIP: create index -> write doc -> search+read -> delete.
t_roundtrip() {
  local idx="verify-rt-$$" doc
  cca -s -o /dev/null -u "elastic:${ELASTIC_PW}" -X PUT "${BASE}/es/${idx}" \
      -H 'Content-Type: application/json' \
      -d '{"settings":{"number_of_replicas":0}}' 2>/dev/null || return 1
  cca -s -o /dev/null -u "elastic:${ELASTIC_PW}" -X POST "${BASE}/es/${idx}/_doc/1?refresh=true" \
      -H 'Content-Type: application/json' -d '{"msg":"hello-roundtrip"}' 2>/dev/null || return 1
  doc="$(cca -s -u "elastic:${ELASTIC_PW}" "${BASE}/es/${idx}/_search?q=msg:hello-roundtrip" 2>/dev/null || true)"
  cca -s -o /dev/null -u "elastic:${ELASTIC_PW}" -X DELETE "${BASE}/es/${idx}" 2>/dev/null || true
  printf '%s' "$doc" | grep -q 'hello-roundtrip'
}
check "Full data round trip (create index, write, search, read back, delete)" t_roundtrip

# 9. SECURITY: ES:9200 and Kibana:5601 are NOT reachable from outside.
t_backends_closed() { ! port_open 9200 && ! port_open 5601; }
check "Elasticsearch:9200 and Kibana:5601 are NOT reachable from outside" t_backends_closed

# 10. Edge certificate: unexpired and its SAN covers the public IP clients use.
t_cert_valid() {
  local pem; pem="$(echo | openssl s_client -connect "${IP}:443" 2>/dev/null | openssl x509 2>/dev/null)"
  [ -n "$pem" ] || return 1
  echo "$pem" | openssl x509 -noout -checkend 0 >/dev/null 2>&1 || return 1
  echo "$pem" | openssl x509 -noout -ext subjectAltName 2>/dev/null | grep -q "IP Address:${IP}"
}
check "Edge certificate is unexpired and its SAN covers ${IP}" t_cert_valid

# --- Cloud-only posture checks --------------------------------------------
section "Cloud posture"

# 11. Only 22 and 443 are open externally.
t_ports_minimal() { port_open 22 && port_open 443 && ! port_open 80 && ! port_open 9300; }
check "External port surface is only 22 and 443 (22 open, 443 open, 80/9300 closed)" t_ports_minimal

# 12. root SSH login is refused.
t_root_ssh_refused() {
  ! ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="$KNOWN_HOSTS" -i "$SSH_KEY" "root@${IP}" true 2>/dev/null
}
check "root SSH login is refused" t_root_ssh_refused

# 13. Password authentication is disabled (only publickey offered).
t_password_auth_disabled() {
  local out
  out="$(ssh -o BatchMode=yes -o ConnectTimeout=10 -o PreferredAuthentications=password \
             -o PubkeyAuthentication=no -o StrictHostKeyChecking=accept-new \
             -o UserKnownHostsFile="$KNOWN_HOSTS" "${ADMIN_USER}@${IP}" true 2>&1 || true)"
  printf '%s' "$out" | grep -qiE 'permission denied \(publickey\)|no more authentication methods'
}
check "Password authentication is disabled (publickey only)" t_password_auth_disabled

# 14. vm.max_map_count is correct and persisted across reboot.
t_max_map_count() {
  local live persist
  live="$(sshx 'sysctl -n vm.max_map_count' 2>/dev/null || echo 0)"
  persist="$(sshx 'cat /etc/sysctl.d/99-elasticsearch.conf 2>/dev/null' 2>/dev/null || echo '')"
  [ "$live" -ge 262144 ] 2>/dev/null && printf '%s' "$persist" | grep -q '262144'
}
check "vm.max_map_count >= 262144 and persisted in /etc/sysctl.d" t_max_map_count

section "Result"
printf '  %sPASS=%d  FAIL=%d%s\n' "$C_BOLD" "$PASS_COUNT" "$FAIL_COUNT" "$C_RESET"
if [ "$FAIL_COUNT" -gt 0 ]; then
  die "verify FAILED (${FAIL_COUNT} assertion(s)). Inspect: ssh ${ADMIN_USER}@${IP} 'journalctl -u elasticsearch -u kibana -u nginx --no-pager | tail -n 120'"
fi
log_ok "All functional and security checks passed."
