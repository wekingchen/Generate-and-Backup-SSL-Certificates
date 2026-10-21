#!/usr/bin/env bash
set -eo pipefail

# 证书路径和 Dropbox 同步目录保持原有约定；本脚本只处理本地 ssl 目录。
if [[ ! -s cloudflare_domains_list.txt || ! -d ssl ]]; then
  echo "::error::域名清单为空或证书同步目录不存在，停止处理以保护 Dropbox 备份。"
  exit 1
fi

updated_domains=""
failed_domains=""
processed=0

# 仅受控生产验收使用；正常定时任务不设置这两个变量。
only_domain="${SSL_ONLY_DOMAIN:-}"
only_type="${SSL_ONLY_TYPE:-}"
if [[ -n "$only_domain" && ! "$only_domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]$ ]]; then
  echo "::error::受控验证指定了非法域名。"
  exit 1
fi
if [[ -n "$only_type" && "$only_type" != EC && "$only_type" != RSA ]]; then
  echo "::error::受控验证指定了非法证书算法。"
  exit 1
fi

certificate_usable() {
  local cert="$1" key="$2" domain="$3" threshold="$4"
  local cert_pub key_pub
  [[ -s "$cert" && -s "$key" ]] || return 1
  openssl x509 -in "$cert" -noout -checkend "$threshold" >/dev/null 2>&1 || return 1
  openssl x509 -in "$cert" -noout -checkhost "$domain" >/dev/null 2>&1 || return 1
  openssl x509 -in "$cert" -noout -checkhost "test.$domain" >/dev/null 2>&1 || return 1
  cert_pub=$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null |
    openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | cut -d ' ' -f1) || return 1
  key_pub=$(openssl pkey -in "$key" -pubout -outform DER 2>/dev/null |
    sha256sum | cut -d ' ' -f1) || return 1
  [[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]]
}

issue_one() {
  local domain="$1" type="$2"
  local src="$HOME/.acme.sh/$domain"
  local dest="./ssl/$domain"
  local keylength="ec-256"
  if [[ "$type" == "EC" ]]; then
    src="$src"_ecc
  else
    dest="$dest/rsa"
    keylength="2048"
  fi

  local certf="$dest/fullchain.cer"
  local keyf="$dest/private.key"
  local logf="$dest/$type"_issue.log
  local threshold=$((DAYS_BEFORE_EXPIRY * 86400))

  if certificate_usable "$certf" "$keyf" "$domain" "$threshold"; then
    echo "— $domain 的 $type 证书仍然有效，跳过。"
    return 0
  fi

  mkdir -p "$dest" || return 1
  echo "→ 生成 $domain 的 $type 证书…"
  if ! "$ACME_PATH" --issue --force --server letsencrypt --dns dns_cf \
    -d "$domain" -d "*.$domain" --keylength "$keylength" >"$logf" 2>&1; then
    echo "::error:: $domain $type 签发失败（日志末尾）："
    tail -n 30 "$logf"
    return 1
  fi

  if ! certificate_usable "$src/fullchain.cer" "$src/$domain.key" "$domain" "$threshold"; then
    echo "::error:: $domain $type 的新证书、域名范围或私钥校验失败。"
    return 1
  fi

  # 先把候选文件放入独立临时目录，避免校验前覆盖旧文件。
  local stage
  stage=$(mktemp -d) || return 1
  if ! cp "$src/fullchain.cer" "$stage/fullchain.cer" ||
     ! cp "$src/$domain.key" "$stage/private.key"; then
    rm -rf "$stage"
    return 1
  fi

  # 失败时保留原始副本，后续整体验证失败会阻止 Dropbox 回写。
  if [[ -f "$certf" ]]; then cp "$certf" "$stage/old-fullchain.cer" || { rm -rf "$stage"; return 1; }; fi
  if [[ -f "$keyf" ]]; then cp "$keyf" "$stage/old-private.key" || { rm -rf "$stage"; return 1; }; fi
  if ! cp "$stage/fullchain.cer" "$certf" || ! cp "$stage/private.key" "$keyf"; then
    [[ ! -f "$stage/old-fullchain.cer" ]] || cp "$stage/old-fullchain.cer" "$certf"
    [[ ! -f "$stage/old-private.key" ]] || cp "$stage/old-private.key" "$keyf"
    rm -rf "$stage"
    return 1
  fi
  rm -rf "$stage"
  if [[ -f "$src/ca.cer" ]]; then cp "$src/ca.cer" "$dest/ca.cer" || return 1; fi

  updated_domains="$updated_domains $domain"
  echo "✔ 已安装 $domain 的 $type 证书。"
  return 0
}

while IFS= read -r domain || [[ -n "$domain" ]]; do
  domain=$(printf '%s' "$domain" | tr -d '\r')
  [[ -z "$domain" || "$domain" == \#* ]] && continue
  [[ -n "$only_domain" && "$domain" != "$only_domain" ]] && continue
  processed=$((processed + 1))

  if [[ ! "$domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]$ ]]; then
    echo "::error::域名列表包含格式异常的条目，已跳过。"
    failed_domains="$failed_domains invalid-entry"
    continue
  fi

  for type in EC RSA; do
    [[ -n "$only_type" && "$type" != "$only_type" ]] && continue
    if ! issue_one "$domain" "$type"; then
      failed_domains="$failed_domains $domain/$type"
      logdir="./ssl/$domain"
      [[ "$type" == RSA ]] && logdir="$logdir/rsa"
      # 同一组域名若已经遭遇 429，另一算法在本轮不再重复消耗申请请求。
      if [[ -f "$logdir/${type}_issue.log" ]] &&
         grep -Eiq '429|rate.?limit|too many certificates|Retry-After' "$logdir/${type}_issue.log"; then
        echo "::warning::$domain 命中签发限额，本次跳过该域名后续算法。"
        break
      fi
    fi
  done
done < cloudflare_domains_list.txt

if [[ "$processed" -eq 0 ]]; then
  echo "::error::域名清单无有效内容，拒绝回写 Dropbox。"
  exit 1
fi

# 每个域名分别记录失败，不中止其他域名；备份之后由工作流统一返回失败状态。
updated_domains=$(printf '%s\n' $updated_domains | sed '/^$/d' | sort -u | paste -sd ',' -)
failed_domains=$(printf '%s\n' $failed_domains | sed '/^$/d' | sort -u | paste -sd ',' -)
if [[ -n "$GITHUB_OUTPUT" ]]; then
  printf 'updated_domains=%s\nfailed_domains=%s\n' "$updated_domains" "$failed_domains" >> "$GITHUB_OUTPUT"
  if [[ -n "$failed_domains" ]]; then echo 'had_failures=true' >> "$GITHUB_OUTPUT"; else echo 'had_failures=false' >> "$GITHUB_OUTPUT"; fi
fi

{
  echo "### SSL 证书处理结果"
  echo ""
  echo "- 已更新域名：$updated_domains"
  echo "- 签发失败：$failed_domains"
  echo "- 说明：仅在后续校验、Dropbox 备份成功后，才视为本轮处理完成。"
} >> "$GITHUB_STEP_SUMMARY"

if [[ -n "$failed_domains" ]]; then
  echo "::warning::部分证书签发失败，仍将尝试备份其他已成功验证的证书。"
fi
