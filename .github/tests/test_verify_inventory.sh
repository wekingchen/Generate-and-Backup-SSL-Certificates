#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TEMP=$(mktemp -d)
trap 'rm -rf "$TEMP"' EXIT
mkdir -p "$TEMP/work/ssl/demo.example" "$TEMP/work/ssl/demo.example/rsa"
echo demo.example > "$TEMP/work/cloudflare_domains_list.txt"

# 测试 CA 全部临时生成；没有外部签发或 Dropbox 写入。
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 100 \
  -subj "/CN=SSL Audit Test Root" -keyout "$TEMP/ca.key" -out "$TEMP/ca.cer" \
  -addext 'basicConstraints=critical,CA:TRUE' >/dev/null 2>&1

make_leaf() {
  local kind="$1" path="$2"
  if [[ "$kind" == EC ]]; then
    openssl ecparam -name prime256v1 -genkey -noout -out "$path/private.key"
  else
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
      -out "$path/private.key" >/dev/null 2>&1
  fi
  openssl req -new -key "$path/private.key" -subj /CN=demo.example -out "$TEMP/leaf.csr"
  printf 'subjectAltName=DNS:demo.example,DNS:*.demo.example\nextendedKeyUsage=serverAuth\n' > "$TEMP/leaf.ext"
  openssl x509 -req -in "$TEMP/leaf.csr" -CA "$TEMP/ca.cer" -CAkey "$TEMP/ca.key" \
    -CAcreateserial -days 75 -sha256 -extfile "$TEMP/leaf.ext" \
    -out "$path/leaf.cer" >/dev/null 2>&1
  cat "$path/leaf.cer" "$TEMP/ca.cer" > "$path/fullchain.cer"
}
make_leaf EC "$TEMP/work/ssl/demo.example"
make_leaf RSA "$TEMP/work/ssl/demo.example/rsa"

test_verifier() {
  SSL_VERIFY_CA_FILE="$TEMP/ca.cer" bash "$ROOT/.github/scripts/verify_certificate.sh" "$@"
}
run_inventory() {
  (cd "$TEMP/work" &&
   SSL_VERIFY_CA_FILE="$TEMP/ca.cer" GITHUB_OUTPUT="$TEMP/output" \
   GITHUB_STEP_SUMMARY="$TEMP/summary" \
   bash "$ROOT/.github/scripts/verify_inventory.sh")
}

echo "Validation Test 1: both algorithms, SAN, trusted chain, matching key"
: > "$TEMP/output"; : > "$TEMP/summary"
run_inventory
grep -Fxq "had_inventory_gaps=false" "$TEMP/output"
grep -Fxq "inventory_missing=" "$TEMP/output"

echo "Validation Test 2: missing RSA must be reported, not quietly healthy"
mv "$TEMP/work/ssl/demo.example/rsa/fullchain.cer" "$TEMP/rsa-backup.cer"
: > "$TEMP/output"
run_inventory
grep -Fxq "had_inventory_gaps=true" "$TEMP/output"
grep -Fxq "inventory_missing=demo.example/RSA" "$TEMP/output"
mv "$TEMP/rsa-backup.cer" "$TEMP/work/ssl/demo.example/rsa/fullchain.cer"

echo "Validation Test 3: mismatched private key must block the backup"
cp "$TEMP/work/ssl/demo.example/rsa/private.key" "$TEMP/mismatch.key"
if test_verifier "$TEMP/work/ssl/demo.example/fullchain.cer" "$TEMP/mismatch.key" demo.example 0; then
  echo "Unmatched key accepted"; exit 1
fi

echo "Validation Test 4: untrusted chain must fail"
openssl req -x509 -newkey rsa:2048 -nodes -days 50 \
  -subj "/CN=Other Test CA" -keyout "$TEMP/other-ca.key" -out "$TEMP/other-ca.cer" \
  >/dev/null 2>&1
if SSL_VERIFY_CA_FILE="$TEMP/other-ca.cer" bash "$ROOT/.github/scripts/verify_certificate.sh" \
  "$TEMP/work/ssl/demo.example/fullchain.cer" "$TEMP/work/ssl/demo.example/private.key" demo.example 0; then
  echo "Untrusted chain accepted"; exit 1
fi

echo "Validation Test 5: incorrect hostname must fail"
if test_verifier "$TEMP/work/ssl/demo.example/fullchain.cer" "$TEMP/work/ssl/demo.example/private.key" wrong.example 0; then
  echo "Incorrect hostname accepted"; exit 1
fi

echo "Validation Test 6: certificate too close to requested lifetime must fail"
if test_verifier "$TEMP/work/ssl/demo.example/fullchain.cer" "$TEMP/work/ssl/demo.example/private.key" demo.example 6912000; then
  echo "Certificate below requested lifetime accepted"; exit 1
fi

echo "All offline inventory and chain validation tests passed."
