#!/usr/bin/env bash
# ===========================================================================
# verify.sh - functional + SECURITY smoke tests against a running deployment.
# Prints a pass/fail table and exits non-zero if any assertion fails. Security
# assertions PROVE the posture (auth enforced, backends isolated) rather than
# assuming it.
# ===========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"

TF_DIR="${REPO_ROOT}/terraform"
ANS_DIR="${REPO_ROOT}/ansible"
CA_CERT="${ANS_DIR}/.certs/ca.crt"
PW_FILE="${ANS_DIR}/.secrets/elastic_password"

# Discover the published port from Terraform state, else fall back.
PORT="$( (cd "$TF_DIR" && terraform output -raw https_url 2>/dev/null) | sed -nE 's#.*:([0-9]+)/?$#\1#p')"
PORT="${PORT:-8443}"
BASE="https://localhost:${PORT}"
ELASTIC_PW="$( [ -f "$PW_FILE" ] && cat "$PW_FILE" || echo "" )"

# curl that trusts our internal CA (real TLS validation, not -k).
cca() { curl --cacert "$CA_CERT" "$@"; }

PASS_COUNT=0; FAIL_COUNT=0
check() { # check "label" test-expr-as-string
  local label="$1"; shift
  if "$@"; then PASS_COUNT=$((PASS_COUNT+1)); printf '  %s[PASS]%s %s\n' "$C_GREEN" "$C_RESET" "$label"
  else FAIL_COUNT=$((FAIL_COUNT+1)); printf '  %s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$label"; fi
}

[ -f "$CA_CERT" ] || die "CA certificate not found at ${CA_CERT}; has the stack been deployed?"

section "Verifying ${BASE}"

# 1. HTTPS responds AND the TLS chain validates against the generated CA.
t_https_valid() {
  local code
  code="$(cca -s -o /dev/null -w '%{http_code}' "${BASE}/" 2>/dev/null || echo 000)"
  [ "$code" = "200" ] || [ "$code" = "302" ]
}
check "HTTPS edge responds and TLS validates against the internal CA" t_https_valid

# 2. Plain HTTP to the TLS port never serves content (we run no plaintext listener).
t_http_refused() {
  # Speaking HTTP to a TLS socket must NOT yield a 200 with a body.
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${PORT}/" 2>/dev/null || echo 000)"
  [ "$code" != "200" ]
}
check "Plain HTTP is refused (no cleartext content served)" t_http_refused

# 3. Elasticsearch cluster health via the proxy is green or yellow.
t_es_health() {
  local body
  body="$(cca -s -u "elastic:${ELASTIC_PW}" "${BASE}/es/_cluster/health" 2>/dev/null || true)"
  echo "$body" | grep -qE '"status":"(green|yellow)"'
}
check "Elasticsearch cluster health is green/yellow (via /es/)" t_es_health

# 4. Kibana reports available.
t_kibana_available() {
  local body
  body="$(cca -s "${BASE}/api/status" 2>/dev/null || true)"
  echo "$body" | grep -q '"level":"available"'
}
check "Kibana status is 'available'" t_kibana_available

# 5. SECURITY: unauthenticated Elasticsearch request is rejected (401/403).
t_es_unauth_rejected() {
  local code
  code="$(cca -s -o /dev/null -w '%{http_code}' "${BASE}/es/_security/_authenticate" 2>/dev/null || echo 000)"
  [ "$code" = "401" ] || [ "$code" = "403" ]
}
check "Unauthenticated Elasticsearch request is rejected (proves security is ON)" t_es_unauth_rejected

# 6. SECURITY: authenticated request succeeds.
t_es_auth_ok() {
  local code
  code="$(cca -s -o /dev/null -w '%{http_code}' -u "elastic:${ELASTIC_PW}" "${BASE}/es/_security/_authenticate" 2>/dev/null || echo 000)"
  [ "$code" = "200" ]
}
check "Authenticated Elasticsearch request succeeds with generated credentials" t_es_auth_ok

# 7. SECURITY: ES and Kibana native ports are NOT reachable from the host.
t_backend_isolated() {
  # No published port -> connection should be refused/time out quickly.
  ! curl -s --max-time 3 -o /dev/null "http://localhost:9200" 2>/dev/null \
    && ! curl -s --max-time 3 -o /dev/null "http://localhost:5601" 2>/dev/null
}
check "Elasticsearch:9200 and Kibana:5601 are NOT reachable from the host" t_backend_isolated

# 8. SECURITY: edge certificate SAN matches 'localhost' and it is not expired.
t_cert_valid() {
  local pem
  pem="$(echo | openssl s_client -connect "localhost:${PORT}" -servername localhost 2>/dev/null \
    | openssl x509 2>/dev/null)"
  [ -n "$pem" ] || return 1
  # Not expired (checkend 0 = valid strictly in the future).
  echo "$pem" | openssl x509 -noout -checkend 0 >/dev/null 2>&1 || return 1
  # SAN or CN covers localhost.
  echo "$pem" | openssl x509 -noout -ext subjectAltName 2>/dev/null | grep -q "DNS:localhost" \
    || echo "$pem" | openssl x509 -noout -subject 2>/dev/null | grep -q "localhost"
}
check "Edge certificate is unexpired and its SAN/CN covers 'localhost'" t_cert_valid

# 9. Kibana serves a real login page (HTTP 200, real HTML) - not 502 and not
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

# 10. FULL ROUND TRIP: create an index, write a doc, search+read it back, then
#     delete the index. Proves data flows, not just that a port answers.
t_roundtrip() {
  local idx="verify-rt-$$" doc
  cca -s -o /dev/null -u "elastic:${ELASTIC_PW}" -X PUT "${BASE}/es/${idx}" \
      -H 'Content-Type: application/json' -d '{"settings":{"number_of_replicas":0}}' 2>/dev/null || return 1
  cca -s -o /dev/null -u "elastic:${ELASTIC_PW}" -X POST "${BASE}/es/${idx}/_doc/1?refresh=true" \
      -H 'Content-Type: application/json' -d '{"msg":"hello-roundtrip"}' 2>/dev/null || return 1
  doc="$(cca -s -u "elastic:${ELASTIC_PW}" "${BASE}/es/${idx}/_search?q=msg:hello-roundtrip" 2>/dev/null || true)"
  cca -s -o /dev/null -u "elastic:${ELASTIC_PW}" -X DELETE "${BASE}/es/${idx}" 2>/dev/null || true
  printf '%s' "$doc" | grep -q 'hello-roundtrip'
}
check "Full data round trip (create index, write, search, read back, delete)" t_roundtrip

section "Result"
printf '  %sPASS=%d  FAIL=%d%s\n' "$C_BOLD" "$PASS_COUNT" "$FAIL_COUNT" "$C_RESET"
if [ "$FAIL_COUNT" -gt 0 ]; then
  die "verify FAILED (${FAIL_COUNT} assertion(s)). Inspect: docker ps; docker logs ${PROJECT_PREFIX:-elk-local}-elasticsearch"
fi
log_ok "All functional and security checks passed."
