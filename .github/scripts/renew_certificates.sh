#!/usr/bin/env bash
set -eo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ca_provider.sh"
ssl_ca_init

# 证书路径和 Dropbox 同步目录保持原有约定；本脚本只处理本地 ssl 目录。
if [[ ! -s cloudflare_domains_list.txt || ! -d ssl ]]; then
  echo "::error::域名清单为空或证书同步目录不存在，停止处理以保护 Dropbox 备份。"
  exit 1
fi

updated_domains=""
updated_certificates=""
certificate_issuers=""
valid_skipped=0
failed_domains=""
processed=0
attempts=0
ca_orders=0
deferred_certificates=""
skipped_duplicates=0
# 用户维护的域名列表是唯一来源。每个有效域名只处理 EC/RSA 各一次。
# 因此单轮理论上最多发起 2 * 有效去重域名数 个签发请求，
# 不再依赖工作流里写死的 2/12/其他全局张数。
declare -A seen_domains=()

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

# 所有 CA 统一走 acme.sh DNS-01；备份目标仍为原有 SSL 文件结构。
acme_# 429 仅在证书进入最后 7 天、且等待期超过 24 小时的安全缓冲时才允许应急切换。
# 无现存有效证书属于首次签发/已过期场景，仍须确认等待期超过缓冲。
certificate_seconds_left() {
  local cert="$1" key="$2" domain="$3" expiry
  if ! certificate_usable "$cert" "$key" "$domain" 0; then
    echo 0
    return
  fi
  expiry=$(openssl x509 -in "$cert" -noout -enddate | sed 's/^notAfter=//')
  echo $(( $(date -u -d "$expiry" +%s) - $(date -u +%s) ))
}

rate_limit_emergency() {
  local remaining="$1" wait_until="$2" now
  now=$(date -u +%s)
  ((remaining <= 7 * 86400 && wait_until > now + 86400))
}

# 优先读取明确的 Retry-After 时间，否则使用已有日志修改时间 +34 小时。
rate_limit_until() {
  local log="$1" retry_text retry_ts log_ts
  retry_text=$(grep -Eoi 'retry after[ :]+[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}( UTC|Z)?' "$log" | tail -n 1 | sed -E 's/^[^0-9]*//' || true)
  retry_ts=0
  if [[ -n "$retry_text" ]]; then
    retry_ts=$(date -u -d "$retry_text" +%s 2>/dev/null || echo 0)
  fi
  if ((retry_ts > 0)); then
    echo "$retry_ts"
  else
    log_ts=$(stat -c %Y "$log" 2>/dev/null || date -u +%s)
    echo $((log_ts + 34 * 3600))
  fi
}

issue_one() {
  local ca="$1" domain="$2" keylength="$3" log="$4"
  ssl_ca_register "$ca" || return 1
  ca_orders=$((ca_orders + 1))
  "$ACME_PATH" --issue --force --server "$ca" --dns dns_cf \
    -d "$domain" -d "*.$domain" --keylength "$keylength" >"$log" 2>&1
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
    valid_skipped=$((valid_skipped + 1))
    return 0
  fi

  mkdir -p "$dest" || return 1

  local remaining_seconds cooldown_until emergency_429=false
  remaining_seconds=$(certificate_seconds_left "$certf" "$keyf" "$domain")
  # 只使用已有 issue 日志记录跨运行 429 冷却，不改变 Dropbox 目录结构。
  if [[ -s "$logf" ]] &&
     grep -Eiq '429|rate.?limit|too many certificates|Retry-After' "$logf"; then
    cooldown_until=$(rate_limit_until "$logf")
    if ((cooldown_until > $(date -u +%s))); then
      if [[ "$SSL_CA_MODE" == auto && "$SSL_FALLBACK_CA" == zerossl ]] &&
         rate_limit_emergency "$remaining_seconds" "$cooldown_until"; then
        emergency_429=true
        echo "::warning::$domain $type 处于 429 冷却期；旧证书剩余约 $((remaining_seconds / 86400)) 天，允许一次 ZeroSSL 应急签发。"
      else
        echo "— $domain $type 处于 429 冷却期，预计 UTC $(date -u -d "@$cooldown_until" +'%Y-%m-%d %H:%M') 后重试；旧证书剩余约 $((remaining_seconds / 86400)) 天。"
        deferred_certificates="$deferred_certificates $domain/$type"
        return 0
      fi
    fi
  fi

  attempts=$((attempts + 1))
  local chosen_ca="$SSL_PRIMARY_CA" fallback_log
  if [[ "$emergency_429" == true ]]; then
    chosen_ca=zerossl
  fi
  echo "→ 生成 $domain 的 $type 证书（$chosen_ca，本轮第 $attempts 次）…"
  # 仅实际发起请求时清空旧日志；预先判断冷却不会破坏上轮限流证据。
  : > "$logf"
  if ! acme_issue_one "$chosen_ca" "$domain" "$keylength" "$logf"; then
    local detected_429=false
    if grep -Eiq '429|rate.?limit|too many certificates|Retry-After' "$logf"; then
      detected_429=true
    fi
    if [[ "$SSL_CA_MODE" == auto && "$SSL_FALLBACK_CA" == zerossl && "$chosen_ca" == letsencrypt ]] &&
       { ssl_ca_transient_error "$logf" ||
         { [[ "$detected_429" == true ]] &&
           rate_limit_emergency "$remaining_seconds" "$(rate_limit_until "$logf")"; }; }; then
      if [[ "$detected_429" == true ]]; then
        echo "::warning::$domain $type 遇到 Let's Encrypt 429，旧证书剩余约 $((remaining_seconds / 86400)) 天，进入 ZeroSSL 应急签发。"
      else
        echo "::warning::$domain $type 的 Let's Encrypt 服务暂时异常，准备受控尝试 ZeroSSL。"
      fi
      # CAA 在 CA 端强制校验；此处只提供诊断提示，不自称实现完整 CAA 解析。
      if command -v dig >/dev/null 2>&1; then
        local caa_records
        caa_records=$(dig +short CAA "$domain" 2>/dev/null || true)
        [[ -z "$caa_records" ]] || echo "— $domain 的 CAA 设置需允许 ZeroSSL（通常为 sectigo.com）。"
      fi
      fallback_log=$(mktemp)
      if acme_issue_one zerossl "$domain" "$keylength" "$fallback_log"; then
        chosen_ca=zerossl
        echo "✔ $domain $type 已由备用 CA ZeroSSL 签发。"
      else
        echo "::error::$domain $type 的备用 CA 签发也失败；未替换旧证书。"
        [[ ! -s "$fallback_log" ]] || tail -n 12 "$fallback_log"
        rm -f "$fallback_log"
        return 1
      fi
      rm -f "$fallback_log"
    else
      echo "::error::$domain $type 的 $chosen_ca 签发失败；不会盲目切换 CA。"
      [[ ! -s "$logf" ]] || tail -n 30 "$logf"
      return 1
    fi
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
  updated_certificates="$updated_certificates $domain/$type"
  certificate_issuers="$certificate_issuers $domain/$type=$chosen_ca"
  echo "✔ 已安装 $domain 的 $type 证书。"
  return 0
}

while IFS= read -r domain || [[ -n "$domain" ]]; do
  domain=$(printf '%s' "$domain" | tr -d '\r')
  [[ -z "$domain" || "$domain" == \#* ]] && continue
  domain="${domain,,}" # DNS 域名不区分大小写；统一大小写便于去重。
  [[ -n "$only_domain" && "$domain" != "${only_domain,,}" ]] && continue

  # 拒绝空标签、连续点号、首尾连字符等错误输入，避免错误签发请求。
  if [[ ! "$domain" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
    echo "::error::域名列表包含格式异常的条目，已跳过。"
    failed_domains="$failed_domains invalid-entry"
    continue
  fi

  if [[ -n "${seen_domains[$domain]+x}" ]]; then
    echo "— $domain 在域名清单中重复，已跳过重复条目。"
    skipped_duplicates=$((skipped_duplicates + 1))
    continue
  fi
  seen_domains["$domain"]=1
  processed=$((processed + 1))

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
        if [[ "$type" == EC && "$only_type" != EC ]]; then
          deferred_certificates="$deferred_certificates $domain/RSA"
        fi
        break
      fi
    fi
  done
done < cloudflare_domains_list.txt

if [[ "$processed" -eq 0 ]]; then
  echo "::error::域名清单无有效内容，拒绝回写 Dropbox。"
  exit 1
fi

# 与静态配额无关，实际单轮请求数由本次远端域名清单动态决定。
max_possible=$((processed * 2))
if ((attempts > max_possible)); then
  echo "::error::签发请求数异常：$attempts > $max_possible，停止处理。"
  exit 1
fi
echo "✔ 本轮有效域名数：$processed；EC/RSA 检查项目上限：$max_possible；实际申请项目：$attempts；CA 发单次数（含备用）：$ca_orders。"

# 每个域名分别记录失败，不中止其他域名；备份之后由工作流统一返回失败状态。
updated_domains=$(printf '%s\n' $updated_domains | sed '/^$/d' | sort -u | paste -sd ',' -)
updated_certificates=$(printf '%s\n' $updated_certificates | sed '/^$/d' | sort -u | paste -sd ',' -)
certificate_issuers=$(printf '%s\n' $certificate_issuers | sed '/^$/d' | sort -u | paste -sd ',' -)
failed_domains=$(printf '%s\n' $failed_domains | sed '/^$/d' | sort -u | paste -sd ',' -)
deferred_certificates=$(printf '%s\n' $deferred_certificates | sed '/^$/d' | sort -u | paste -sd ',' -)
if [[ -n "$GITHUB_OUTPUT" ]]; then
  printf 'updated_domains=%s\nupdated_certificates=%s\ncertificate_issuers=%s\nfailed_domains=%s\ndeferred_certificates=%s\nchecked_domains=%s\nvalid_skipped=%s\nattempts=%s\nca_orders=%s\n' \
    "$updated_domains" "$updated_certificates" "$certificate_issuers" "$failed_domains" "$deferred_certificates" "$processed" "$valid_skipped" "$attempts" "$ca_orders" >> "$GITHUB_OUTPUT"
  if [[ -n "$failed_domains" ]]; then echo 'had_failures=true' >> "$GITHUB_OUTPUT"; else echo 'had_failures=false' >> "$GITHUB_OUTPUT"; fi
fi

{
  echo "### SSL 证书处理结果"
  echo ""
  echo "- 已更新域名：$updated_domains"
  echo "- 已更新证书类型：$updated_certificates"
  echo "- 实际签发机构：$certificate_issuers"
  echo "- 主 CA：$SSL_PRIMARY_CA；备用 CA：$SSL_FALLBACK_CA"
  echo "- 原证书仍有效：$valid_skipped 张"
  echo "- 签发失败：$failed_domains"
  echo "- 限额冷却待重试：$deferred_certificates"
  echo "- 有效域名数（去重）：$processed"
  echo "- 重复域名条目：$skipped_duplicates"
  echo "- 动态最大检查项目数（域名数 × 2）：$max_possible"
  echo "- 本轮需申请的证书项目：$attempts"
  echo "- 本轮 CA 发单次数（含备用重试）：$ca_orders"
  echo "- 说明：仅在后续校验、Dropbox 备份成功后，才视为本轮处理完成。"
} >> "$GITHUB_STEP_SUMMARY"

if [[ -n "$failed_domains" ]]; then
  echo "::warning::部分证书签发失败，仍将尝试备份其他已成功验证的证书。"
fi
