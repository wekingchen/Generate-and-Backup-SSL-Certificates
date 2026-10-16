#!/usr/bin/env bash
set -euo pipefail

# Fully offline regression test for renew_certificates.sh.
# This file also acts as a fake acme.sh executable when called with --issue.
if [[ "${1:-}" == "--issue" ]]; then
  domain=""
  keylength=""
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      -d) [[ -n "$domain" ]] || domain="$2"; shift 2 ;;
      --keylength) keylength="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ -n "$domain" && -n "$keylength" ]]
  printf '%s/%s\n' "$domain" "$keylength" >> "$MOCK_ACME_CALLS"
  if [[ "$domain" == "${FAIL_DOMAIN:-}" ]]; then
    echo "Simulated ACME failure for $domain" >&2
    exit 37
  fi
  type=RSA
  suffix=""
  if [[ "$keylength" == "ec-256" ]]; then type=EC; suffix="_ecc"; fi
  src="$CERT_FIXTURES/$domain/$type"
  dst="$HOME/.acme.sh/$domain$suffix"
  mkdir -p "$dst"
  cp "$src/fullchain.cer" "$dst/fullchain.cer"
  cp "$src/private.key" "$dst/$domain.key"
  if [[ "$domain" == "${MISMATCH_DOMAIN:-}" && "$type" == EC ]]; then
    cp "$CERT_FIXTURES/wrong.example/EC/private.key" "$dst/$domain.key"
  fi
  exit 0
fi

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
RENEW_SCRIPT="$REPO_ROOT/.github/scripts/renew_certificates.sh"
TEST_SCRIPT="$REPO_ROOT/.github/tests/test_renew_certificates.sh"
chmod +x "$TEST_SCRIPT"
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

make_pair() {
  local domain="$1" type="$2" target="$3" days="${4:-90}"
  mkdir -p "$target"
  if [[ "$type" == EC ]]; then
    openssl ecparam -name prime256v1 -genkey -noout -out "$target/private.key"
    openssl req -x509 -new -sha256 -days "$days" -key "$target/private.key" \
      -subj "/CN=$domain" -addext "subjectAltName=DNS:$domain,DNS:*.$domain" \
      -out "$target/fullchain.cer" >/dev/null 2>&1
  else
    openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days "$days" \
      -keyout "$target/private.key" -out "$target/fullchain.cer" \
      -subj "/CN=$domain" -addext "subjectAltName=DNS:$domain,DNS:*.$domain" \
      >/dev/null 2>&1
  fi
}

new_case() {
  CASE_DIR="$TEST_TMP/$1"
  mkdir -p "$CASE_DIR/work/ssl" "$CASE_DIR/home" "$CASE_DIR/fixtures"
  : > "$CASE_DIR/outputs"
  : > "$CASE_DIR/summary"
}

run_case() {
  ( cd "$CASE_DIR/work" && \
    HOME="$CASE_DIR/home" \
    DAYS_BEFORE_EXPIRY=30 \
    ACME_PATH="$TEST_SCRIPT" \
    GITHUB_OUTPUT="$CASE_DIR/outputs" \
    GITHUB_STEP_SUMMARY="$CASE_DIR/summary" \
    CERT_FIXTURES="$CASE_DIR/fixtures" \
    MOCK_ACME_CALLS="$CASE_DIR/calls" \
    FAIL_DOMAIN="${FAIL_DOMAIN:-}" \
    MISMATCH_DOMAIN="${MISMATCH_DOMAIN:-}" \
    bash "$RENEW_SCRIPT" )
}

assert_output() {
  if ! grep -Fxq "$1" "$CASE_DIR/outputs"; then
    echo "Expected output not found: $1"
    cat "$CASE_DIR/outputs"
    exit 1
  fi
}

echo "Test 1: current EC and RSA certificates do not trigger ACME"
new_case "skip"
make_pair good.example EC "$CASE_DIR/work/ssl/good.example"
make_pair good.example RSA "$CASE_DIR/work/ssl/good.example/rsa"
printf 'good.example\n' > "$CASE_DIR/work/cloudflare_domains_list.txt"
run_case
assert_output "had_failures=false"
assert_output "updated_domains="
assert_output "failed_domains="
[[ ! -e "$CASE_DIR/calls" ]]

echo "Test 2: one failed domain does not prevent another from being issued"
new_case "partial"
make_pair renew.example EC "$CASE_DIR/fixtures/renew.example/EC"
make_pair renew.example RSA "$CASE_DIR/fixtures/renew.example/RSA"
printf 'renew.example\nbad.example\n' > "$CASE_DIR/work/cloudflare_domains_list.txt"
FAIL_DOMAIN=bad.example run_case
assert_output "had_failures=true"
assert_output "updated_domains=renew.example"
assert_output "failed_domains=bad.example/EC,bad.example/RSA"
[[ -s "$CASE_DIR/work/ssl/renew.example/fullchain.cer" ]]
[[ -s "$CASE_DIR/work/ssl/renew.example/private.key" ]]
[[ -s "$CASE_DIR/work/ssl/renew.example/rsa/fullchain.cer" ]]
[[ -s "$CASE_DIR/work/ssl/renew.example/rsa/private.key" ]]
[[ ! -s "$CASE_DIR/work/ssl/bad.example/fullchain.cer" ]]
[[ -s "$CASE_DIR/work/ssl/bad.example/EC_issue.log" ]]
[[ -s "$CASE_DIR/work/ssl/bad.example/rsa/RSA_issue.log" ]]
[[ "$(wc -l < "$CASE_DIR/calls")" -eq 4 ]]

echo "Test 3: invalid replacement key cannot overwrite the existing EC pair"
new_case "mismatch"
make_pair mismatch.example EC "$CASE_DIR/work/ssl/mismatch.example" 1
make_pair mismatch.example RSA "$CASE_DIR/work/ssl/mismatch.example/rsa" 1
make_pair mismatch.example EC "$CASE_DIR/fixtures/mismatch.example/EC"
make_pair mismatch.example RSA "$CASE_DIR/fixtures/mismatch.example/RSA"
make_pair wrong.example EC "$CASE_DIR/fixtures/wrong.example/EC"
original_cert=$(sha256sum "$CASE_DIR/work/ssl/mismatch.example/fullchain.cer" | cut -d ' ' -f1)
original_key=$(sha256sum "$CASE_DIR/work/ssl/mismatch.example/private.key" | cut -d ' ' -f1)
printf 'mismatch.example\n' > "$CASE_DIR/work/cloudflare_domains_list.txt"
MISMATCH_DOMAIN=mismatch.example run_case
assert_output "had_failures=true"
assert_output "updated_domains=mismatch.example"
assert_output "failed_domains=mismatch.example/EC"
[[ "$(sha256sum "$CASE_DIR/work/ssl/mismatch.example/fullchain.cer" | cut -d ' ' -f1)" == "$original_cert" ]]
[[ "$(sha256sum "$CASE_DIR/work/ssl/mismatch.example/private.key" | cut -d ' ' -f1)" == "$original_key" ]]

echo "Test 4: empty domain list fails without calling ACME"
new_case "empty"
printf '# no domains\n' > "$CASE_DIR/work/cloudflare_domains_list.txt"
if run_case; then
  echo "Empty domain list should fail"
  exit 1
fi
[[ ! -e "$CASE_DIR/calls" ]]

echo "All offline SSL renewal regression tests passed."
