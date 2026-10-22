#!/usr/bin/env bash
set -euo pipefail

# 自身兼作假 acme.sh，以下两段不接触真实网络。
if [[ "${1:-}" == "--register-account" ]]; then
  ca=""
  while (($#)); do
    if [[ "$1" == "--server" ]]; then ca="$2"; shift 2; else shift; fi
  done
  printf '%s\n' "$ca" >> "$MOCK_REG_CALLS"
  exit 0
fi

if [[ "${1:-}" == "--issue" ]]; then
  ca="" domain="" keylen=""
  while (($#)); do
    case "$1" in
      --server) ca="$2"; shift 2 ;;
      -d) [[ -n "$domain" ]] || domain="$2"; shift 2 ;;
      --keylength) keylen="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  printf '%s/%s\n' "$domain" "$ca" >> "$MOCK_CA_CALLS"
  if [[ "$ca" == letsencrypt && "${MOCK_LE_FAIL:-}" == "503" ]]; then
    echo "HTTP 503 Service Unavailable" >&2
    exit 37
  fi
  if [[ "$ca" == letsencrypt && "${MOCK_LE_FAIL:-}" == "429" ]]; then
    echo "HTTP 429 rateLimited too many certificates" >&2
    exit 37
  fi
  suffix="" 
  [[ "$keylen" == ec-256 ]] && suffix="_ecc"
  mkdir -p "$HOME/.acme.sh/$domain$suffix"
  cp "$MOCK_FIXTURE/fullchain.cer" "$HOME/.acme.sh/$domain$suffix/fullchain.cer"
  cp "$MOCK_FIXTURE/private.key" "$HOME/.acme.sh/$domain$suffix/$domain.key"
  exit 0
fi

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
RENEW="$ROOT/.github/scripts/renew_certificates.sh"
chmod +x "$ROOT/.github/tests/test_multi_ca.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/fixture"
openssl ecparam -name prime256v1 -genkey -noout -out "$TMP/fixture/private.key"
openssl req -x509 -new -sha256 -days 90 -key "$TMP/fixture/private.key" \
  -subj "/CN=multi.example" -addext "subjectAltName=DNS:multi.example,DNS:*.multi.example" \
  -out "$TMP/fixture/fullchain.cer" >/dev/null 2>&1

new_case() {
  CASE="$TMP/$1"
  mkdir -p "$CASE/home" "$CASE/work/ssl"
  printf 'multi.example\n' > "$CASE/work/cloudflare_domains_list.txt"
  : > "$CASE/output"
  : > "$CASE/summary"
}

run_case() {
  (cd "$CASE/work" &&
  env \
    HOME="$CASE/home" \
    ACME_PATH="$ROOT/.github/tests/test_multi_ca.sh" \
    DAYS_BEFORE_EXPIRY=30 \
    GITHUB_EVENT_NAME="${GITHUB_EVENT_NAME:-workflow_dispatch}" \
    GITHUB_OUTPUT="$CASE/output" GITHUB_STEP_SUMMARY="$CASE/summary" \
    MOCK_CA_CALLS="$CASE/ca_calls" MOCK_REG_CALLS="$CASE/registers" \
    MOCK_FIXTURE="$TMP/fixture" MOCK_LE_FAIL="${MOCK_LE_FAIL:-}" \
    SSL_ONLY_TYPE=EC SSL_CA_MODE="${SSL_CA_MODE:-auto}" \
    SSL_FALLBACK_CA="${SSL_FALLBACK_CA:-off}" \
    ZEROSSL_EAB_KID="${ZEROSSL_EAB_KID:-}" \
    ZEROSSL_EAB_HMAC_KEY="${ZEROSSL_EAB_HMAC_KEY:-}" \
    GOOGLE_EAB_KID="${GOOGLE_EAB_KID:-}" \
    GOOGLE_EAB_HMAC_KEY="${GOOGLE_EAB_HMAC_KEY:-}" \
    EMAIL=test@example.invalid \
    bash "$RENEW")
}

expect_output() { grep -Fxq "$1" "$CASE/output"; }

echo "Multi-CA Test 1: default LE remains unchanged"
new_case "default"
run_case
expect_output "certificate_issuers=multi.example/EC=letsencrypt"
expect_output "ca_orders=1"
grep -Fxq "multi.example/letsencrypt" "$CASE/ca_calls"
[[ ! -e "$CASE/registers" ]]

echo "Multi-CA Test 2: explicit ZeroSSL needs EAB and uses its server"
new_case "manual-zero"
SSL_CA_MODE=zerossl ZEROSSL_EAB_KID=kid ZEROSSL_EAB_HMAC_KEY=secret run_case
expect_output "certificate_issuers=multi.example/EC=zerossl"
grep -Fxq "zerossl" "$CASE/registers"
grep -Fxq "multi.example/zerossl" "$CASE/ca_calls"

echo "Multi-CA Test 3: opt-in LE 503 switches to ZeroSSL, counts both CA orders"
new_case "503-fallback"
SSL_FALLBACK_CA=zerossl MOCK_LE_FAIL=503 \
  ZEROSSL_EAB_KID=kid ZEROSSL_EAB_HMAC_KEY=secret run_case
expect_output "had_failures=false"
expect_output "certificate_issuers=multi.example/EC=zerossl"
expect_output "attempts=1"
expect_output "ca_orders=2"
[[ "$(wc -l < "$CASE/ca_calls")" -eq 2 ]]

echo "Multi-CA Test 4: first issuance + 429 switches once after 34h fallback window"
new_case "429-first-issuance"
SSL_FALLBACK_CA=zerossl MOCK_LE_FAIL=429 \
  ZEROSSL_EAB_KID=kid ZEROSSL_EAB_HMAC_KEY=secret run_case
expect_output "had_failures=false"
expect_output "certificate_issuers=multi.example/EC=zerossl"
expect_output "ca_orders=2"
[[ "$(wc -l < "$CASE/ca_calls")" -eq 2 ]]

echo "Multi-CA Test 4b: 429 with 20-day valid certificate does NOT switch"
new_case "429-no-switch"
mkdir -p "$CASE/work/ssl/multi.example"
openssl req -x509 -new -sha256 -days 20 -key "$TMP/fixture/private.key" \
  -subj "/CN=multi.example" -addext "subjectAltName=DNS:multi.example,DNS:*.multi.example" \
  -out "$CASE/work/ssl/multi.example/fullchain.cer" >/dev/null 2>&1
cp "$TMP/fixture/private.key" "$CASE/work/ssl/multi.example/private.key"
SSL_FALLBACK_CA=zerossl MOCK_LE_FAIL=429 \
  ZEROSSL_EAB_KID=kid ZEROSSL_EAB_HMAC_KEY=secret run_case
expect_output "had_failures=true"
expect_output "ca_orders=1"
[[ "$(wc -l < "$CASE/ca_calls")" -eq 1 ]]
[[ ! -e "$CASE/registers" ]]

echo "Multi-CA Test 4c: 429 with 5-day certificate switches to ZeroSSL"
new_case "429-near-expiry"
mkdir -p "$CASE/work/ssl/multi.example"
openssl req -x509 -new -sha256 -days 5 -key "$TMP/fixture/private.key" \
  -subj "/CN=multi.example" -addext "subjectAltName=DNS:multi.example,DNS:*.multi.example" \
  -out "$CASE/work/ssl/multi.example/fullchain.cer" >/dev/null 2>&1
cp "$TMP/fixture/private.key" "$CASE/work/ssl/multi.example/private.key"
SSL_FALLBACK_CA=zerossl MOCK_LE_FAIL=429 \
  ZEROSSL_EAB_KID=kid ZEROSSL_EAB_HMAC_KEY=secret run_case
expect_output "had_failures=false"
expect_output "certificate_issuers=multi.example/EC=zerossl"
expect_output "ca_orders=2"

echo "Multi-CA Test 5: missing EAB cannot bypass primary failure"
new_case "missing-eab"
SSL_FALLBACK_CA=zerossl MOCK_LE_FAIL=503 run_case
expect_output "had_failures=true"
expect_output "ca_orders=1"
[[ "$(wc -l < "$CASE/ca_calls")" -eq 1 ]]

echo "Multi-CA Test 6: manually selected Google uses Google ACME EAB"
new_case "google-manual"
SSL_CA_MODE=google GOOGLE_EAB_KID=kid GOOGLE_EAB_HMAC_KEY=secret run_case
expect_output "certificate_issuers=multi.example/EC=google"
grep -Fxq "google" "$CASE/registers"
grep -Fxq "multi.example/google" "$CASE/ca_calls"

echo "Multi-CA Test 7: invalid modes and scheduled Google fail closed"
new_case "invalid"
if SSL_CA_MODE=unknown run_case; then echo "Accepted invalid CA"; exit 1; fi
if SSL_FALLBACK_CA=google run_case; then echo "Accepted unsupported fallback"; exit 1; fi
if SSL_CA_MODE=google GITHUB_EVENT_NAME=schedule run_case; then
  echo "Scheduled Google unexpectedly allowed"; exit 1
fi
[[ ! -e "$CASE/ca_calls" ]]

echo "All isolated multi-CA tests passed."
