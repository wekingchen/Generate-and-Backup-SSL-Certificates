#!/usr/bin/env bash
set -euo pipefail

# 用法：verify_certificate.sh <fullchain.cer> <private.key> <根域名> [剩余有效秒数]
# 校验根域名与通配符、私钥匹配、证书有效期和系统可信证书链。
cert="${1:?缺少证书路径}"
key="${2:?缺少私钥路径}"
domain="${3:?缺少根域名}"
threshold="${4:-0}"
expected_type="${5:-}"
[[ -s "$cert" && -s "$key" ]] || { echo "::error::$domain 证书或私钥不存在。"; exit 1; }
openssl x509 -in "$cert" -noout -checkend "$threshold" >/dev/null || { echo "::error::$domain 证书已过期或未达到有效期阈值。"; exit 1; }
openssl x509 -in "$cert" -noout -checkhost "$domain" >/dev/null || { echo "::error::$domain 证书未覆盖根域名。"; exit 1; }
openssl x509 -in "$cert" -noout -checkhost "test.$domain" >/dev/null || { echo "::error::$domain 证书未覆盖通配符域名。"; exit 1; }
openssl x509 -in "$cert" -noout -ext subjectAltName | grep -Fq "DNS:*.$domain" || { echo "::error::$domain 缺少明确的通配符 SAN。"; exit 1; }
cert_pub=$(openssl x509 -in "$cert" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum | cut -d" " -f1)
key_pub=$(openssl pkey -in "$key" -pubout -outform DER | sha256sum | cut -d" " -f1)
[[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]] || { echo "::error::$domain 证书与私钥不匹配。"; exit 1; }
# 确保证书目录中的算法与设计一致，防止 RSA/EC 被意外装反。
case "$expected_type" in
  EC)
    openssl pkey -in "$key" -noout -text 2>/dev/null | grep -F "ASN1 OID: prime256v1" >/dev/null ||
      { echo "::error::$domain 期待 EC P-256 私钥，实际类型不符。"; exit 1; }
    ;;
  RSA)
    openssl rsa -in "$key" -noout -text 2>/dev/null | grep -F "Private-Key: (2048 bit" >/dev/null ||
      { echo "::error::$domain 期待 RSA 2048 私钥，实际类型不符。"; exit 1; }
    ;;
  "") ;;
  *) echo "::error::无效的预期证书算法：$expected_type"; exit 1 ;;
esac
# 测试可通过 SSL_VERIFY_CA_FILE 配置临时自签根证书，生产使用操作系统信任库。
if [[ -n "${SSL_VERIFY_CA_FILE:-}" ]]; then
  openssl verify -purpose sslserver -CAfile "$SSL_VERIFY_CA_FILE" -untrusted "$cert" "$cert" >/dev/null || { echo "::error::$domain 证书链不受信任。"; exit 1; }
else
  openssl verify -purpose sslserver -CApath /etc/ssl/certs -untrusted "$cert" "$cert" >/dev/null || { echo "::error::$domain 证书链不受信任。"; exit 1; }
fi
echo "✔ $domain：有效期、根域名、通配符、私钥及证书链均校验通过。"
