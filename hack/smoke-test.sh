#!/usr/bin/env bash
# End-to-end check of the deployed app through the ingress, over TLS.
#
# Verifies that:
#   1. https://wisecow.local returns 200 with a cow in the body, and the server
#      certificate validates against the cluster's private CA (no -k)
#   2. plain http:// is redirected to https://
#
# Env: HOST (default wisecow.local), ADDR (default 127.0.0.1)
set -euo pipefail

HOST="${HOST:-wisecow.local}"
ADDR="${ADDR:-127.0.0.1}"
NAMESPACE="wisecow"
CA_FILE="$(mktemp)"
trap 'rm -f "$CA_FILE"' EXIT

kubectl -n "$NAMESPACE" get secret wisecow-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > "$CA_FILE"

pass() { printf '  PASS  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*" >&2; exit 1; }

echo "==> HTTPS request to https://$HOST/ (verified against wisecow CA)"
ok=""
for attempt in $(seq 1 15); do
  body="$(curl -sS --fail --max-time 5 --cacert "$CA_FILE" \
            --resolve "$HOST:443:$ADDR" "https://$HOST/" 2>/dev/null)" && ok=1 && break
  echo "  attempt $attempt failed, retrying in 2s..."
  sleep 2
done
[ -n "$ok" ] || fail "no successful HTTPS response from https://$HOST/"
grep -q '(oo)' <<<"$body" || fail "response does not contain a cow"
pass "HTTPS 200 with valid certificate, body contains a cow"
printf '%s\n' "$body" | sed 's/^/        /'

echo "==> TLS certificate presented by the ingress"
curl -sS -o /dev/null --max-time 5 --cacert "$CA_FILE" --resolve "$HOST:443:$ADDR" \
     -w '  TLS verify result: %{ssl_verify_result} (0 = OK)\n' "https://$HOST/"
echo | openssl s_client -connect "$ADDR:443" -servername "$HOST" 2>/dev/null \
     | openssl x509 -noout -subject -issuer -enddate | sed 's/^/        /'

echo "==> Plain HTTP must redirect to HTTPS"
read -r code location < <(curl -sS -o /dev/null --max-time 5 --resolve "$HOST:80:$ADDR" \
                              -w '%{http_code} %{redirect_url}\n' "http://$HOST/")
[[ "$code" =~ ^30[1278]$ && "$location" == https://* ]] \
  || fail "expected 301/302/307/308 to https, got $code ${location:-<none>}"
pass "http://$HOST/ -> $code $location"

echo "==> All smoke tests passed"
