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
  if [[ "$domain" == "${RATE_LIMIT_DOMAIN:-}" ]]; then
    echo "HTTP 429 rateLimited: too many certificates for exact set" >&2
    exit 37
  fi
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
    RATE_LIMIT_DOMAIN="${RATE_LIMIT_DOMAIN:-}" \
    SSL_ONLY_DOMAIN="${SSL_ONLY_DOMAIN:-}" \
    SSL_ONLY_TYPE="${SSL_ONLY_TYPE:-}" \
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
assert_output "updated_certificates="
assert_output "failed_domains="
assert_output "valid_skipped=2"
assert_output "checked_domains=1"
assert_output "attempts=0"
[[ ! -e "$CASE_DIR/calls" ]]

echo "Test 2: one failed domain does not prevent another from being issued"
new_case "partial"
make_pair renew.example EC "$CASE_DIR/fixtures/renew.example/EC"
make_pair renew.example RSA "$CASE_DIR/fixtures/renew.example/RSA"
printf 'renew.example\nbad.example\n' > "$CASE_DIR/work/cloudflare_domains_list.txt"
FAIL_DOMAIN=bad.example run_case
assert_output "had_failures=true"
assert_output "updated_domains=renew.example"
assert_output "updated_certificates=renew.example/EC,renew.example/RSA"
assert_output "failed_domains=bad.example/EC,bad.example/RSA"
assert_output "attempts=4"
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


echo "Test 5: one domain and one algorithm is allowed for controlled acceptance"
new_case "selected"
make_pair chosen.example EC "$CASE_DIR/fixtures/chosen.example/EC"
make_pair other.example EC "$CASE_DIR/work/ssl/other.example"
make_pair other.example RSA "$CASE_DIR/work/ssl/other.example/rsa"
printf 'chosen.example\nother.example\n' > "$CASE_DIR/work/cloudflare_domains_list.txt"
SSL_ONLY_DOMAIN=chosen.example SSL_ONLY_TYPE=EC run_case
assert_output "had_failures=false"
assert_output "updated_domains=chosen.example"
assert_output "updated_certificates=chosen.example/EC"
[[ -s "$CASE_DIR/work/ssl/chosen.example/fullchain.cer" ]]
[[ ! -e "$CASE_DIR/work/ssl/chosen.example/rsa/fullchain.cer" ]]
[[ "$(wc -l < "$CASE_DIR/calls")" -eq 1 ]]

echo "Test 6: 429 rate limit stops another algorithm for that domain in the same run"
new_case "rate-limit"
printf 'limited.example\n' > "$CASE_DIR/work/cloudflare_domains_list.txt"
RATE_LIMIT_DOMAIN=limited.example run_case
assert_output "had_failures=true"
assert_output "failed_domains=limited.example/EC"
assert_output "deferred_certificates=limited.example/RSA"
[[ "$(wc -l < "$CASE_DIR/calls")" -eq 1 ]]


echo "Test 7: dynamic batch processes all eligible pairs with no fixed cap"
new_case "batch"
for name in first.example second.example; do
  make_pair "$name" EC "$CASE_DIR/fixtures/$name/EC"
  make_pair "$name" RSA "$CASE_DIR/fixtures/$name/RSA"
done
printf 'first.example\nsecond.example\n' > "$CASE_DIR/work/cloudflare_domains_list.txt"
run_case
assert_output "had_failures=false"
assert_output "updated_domains=first.example,second.example"
assert_output "deferred_certificates="
[[ "$(wc -l < "$CASE_DIR/calls")" -eq 4 ]]
grep -Fqx -- '- 动态最大请求数（域名数 × 2）：4' "$CASE_DIR/summary"

echo "Test 8: a persisted 429 retry-after prevents any further CA requests"
new_case "cooldown"
mkdir -p "$CASE_DIR/work/ssl/cool.example"
printf 'HTTP 429 rateLimited: retry after 2099-01-01 00:00:00 UTC\n' \
  > "$CASE_DIR/work/ssl/cool.example/EC_issue.log"
make_pair cool.example RSA "$CASE_DIR/work/ssl/cool.example/rsa"
printf 'cool.example\n' > "$CASE_DIR/work/cloudflare_domains_list.txt"
run_case
assert_output "had_failures=false"
assert_output "deferred_certificates=cool.example/EC"
[[ ! -e "$CASE_DIR/calls" ]]

echo "Test 9: 429 without Retry-After falls back to log mtime-based cooldown"
new_case "fallback"
mkdir -p "$CASE_DIR/work/ssl/fallback.example"
printf 'HTTP 429 rateLimited too many certificates\n' > "$CASE_DIR/work/ssl/fallback.example/EC_issue.log"
make_pair fallback.example RSA "$CASE_DIR/work/ssl/fallback.example/rsa"
printf 'fallback.example\n' > "$CASE_DIR/work/cloudflare_domains_list.txt"
run_case
assert_output "had_failures=false"
assert_output "deferred_certificates=fallback.example/EC"
[[ ! -e "$CASE_DIR/calls" ]]


echo "Test 10: domain list growth automatically covers seven EC/RSA pairs"
new_case "seven-domains"
: > "$CASE_DIR/work/cloudflare_domains_list.txt"
for i in 1 2 3 4 5 6 7; do
  name="batch${i}.example"
  make_pair "$name" EC "$CASE_DIR/fixtures/$name/EC"
  make_pair "$name" RSA "$CASE_DIR/fixtures/$name/RSA"
  printf '%s\n' "$name" >> "$CASE_DIR/work/cloudflare_domains_list.txt"
done
run_case
assert_output "had_failures=false"
assert_output "deferred_certificates="
[[ "$(wc -l < "$CASE_DIR/calls")" -eq 14 ]]
[[ -s "$CASE_DIR/work/ssl/batch7.example/rsa/fullchain.cer" ]]
grep -Fqx -- '- 动态最大请求数（域名数 × 2）：14' "$CASE_DIR/summary"

echo "Test 11: list shrink and duplicate/case-insensitive entries are processed once"
new_case "duplicate"
make_pair single.example EC "$CASE_DIR/fixtures/single.example/EC"
make_pair single.example RSA "$CASE_DIR/fixtures/single.example/RSA"
printf '# comment\n\nsingle.example\nSINGLE.EXAMPLE\nsingle.example\n' > "$CASE_DIR/work/cloudflare_domains_list.txt"
run_case
assert_output "had_failures=false"
assert_output "updated_domains=single.example"
[[ "$(wc -l < "$CASE_DIR/calls")" -eq 2 ]]
grep -Fqx -- '- 重复域名条目：2' "$CASE_DIR/summary"
grep -Fqx -- '- 动态最大请求数（域名数 × 2）：2' "$CASE_DIR/summary"

echo "Test 12: invalid entry does not trigger CA order"
new_case "invalid"
make_pair okay.example EC "$CASE_DIR/fixtures/okay.example/EC"
make_pair okay.example RSA "$CASE_DIR/fixtures/okay.example/RSA"
printf 'bad..example\nokay.example\n' > "$CASE_DIR/work/cloudflare_domains_list.txt"
run_case
assert_output "had_failures=true"
assert_output "failed_domains=invalid-entry"
[[ "$(wc -l < "$CASE_DIR/calls")" -eq 2 ]]
grep -Fqx -- '- 动态最大请求数（域名数 × 2）：2' "$CASE_DIR/summary"

echo "All offline SSL renewal regression tests passed."
