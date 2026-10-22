#!/usr/bin/env bash
set -euo pipefail

# 证书签发后统一核对 Dropbox 同步副本中的域名清单和每张 EC/RSA 证书。
# 缺失项目允许其他有效证书继续备份，但向最终状态和 Bark 报告异常。
[[ -s cloudflare_domains_list.txt && -d ssl ]] || { echo "::error::缺少域名清单或证书目录。"; exit 1; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
missing=""
checked=0
valid=0
declare -A seen=()
while IFS= read -r domain || [[ -n "$domain" ]]; do
  domain="${domain//$'\r'/}"
  domain="${domain,,}"
  [[ -z "$domain" || "$domain" == \#* ]] && continue
  if [[ ! "$domain" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
    echo "::error::证书清单包含非法域名。"; exit 1
  fi
  [[ -n "${seen[$domain]+x}" ]] && continue
  seen["$domain"]=1
  for type in EC RSA; do
    checked=$((checked+1))
    dest="ssl/$domain"
    [[ "$type" == RSA ]] && dest="$dest/rsa"
    cert="$dest/fullchain.cer"
    key="$dest/private.key"
    if [[ ! -s "$cert" || ! -s "$key" ]]; then
      missing="$missing $domain/$type"
      echo "::warning::$domain $type 证书或私钥缺失；保留其他有效证书的备份流程。"
      continue
    fi
    bash "$ROOT/.github/scripts/verify_certificate.sh" "$cert" "$key" "$domain" 0 || exit 1
    valid=$((valid+1))
  done
done < cloudflare_domains_list.txt
((checked > 0 && valid > 0)) || { echo "::error::没有任何可用证书，拒绝备份。"; exit 1; }
missing=$(printf '%s\n' $missing | sed '/^$/d' | LC_ALL=C sort -u | paste -sd ',' -)
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "inventory_missing=$missing" >> "$GITHUB_OUTPUT"
  if [[ -n "$missing" ]]; then echo "had_inventory_gaps=true" >> "$GITHUB_OUTPUT"; else echo "had_inventory_gaps=false" >> "$GITHUB_OUTPUT"; fi
fi
echo "✔ 共检查 $checked 张证书，已通过完整验证 $valid 张；缺失项：${missing:-无}。"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  { echo "### 全链路证书清单校验"; echo "- 应有：$checked 张"; echo "- 验证通过：$valid 张"; echo "- 缺失：${missing:-无}"; } >> "$GITHUB_STEP_SUMMARY"
fi
