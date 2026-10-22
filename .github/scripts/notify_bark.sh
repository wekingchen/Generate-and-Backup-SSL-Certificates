#!/usr/bin/env bash
set -euo pipefail

# Bark 只负责结果通知；不接触证书、Cloudflare 或 Dropbox。
# BARK_URL 沿用现有的 https://server/<device_key> 格式，使用 Bark 官方 POST JSON 接口。
if [[ -z "${BARK_URL:-}" ]]; then
  echo "未配置 BARK_URL，跳过通知。"
  exit 0
fi

updated="${UPDATED_CERTIFICATES:-}"
failed="${FAILED_CERTIFICATES:-}"
deferred="${DEFERRED_CERTIFICATES:-}"
checked="${CHECKED_DOMAINS:-0}"
valid_skipped="${VALID_SKIPPED:-0}"
attempts="${ISSUE_ATTEMPTS:-0}"
issuers="${CERTIFICATE_ISSUERS:-}"

# 只有所有关键步骤都通过，才算整个处理过程完整成功。
problem=0
for outcome in "${RENEW_OUTCOME:-skipped}" "${VERIFY_OUTCOME:-skipped}" \
               "${GUARD_OUTCOME:-skipped}" "${BACKUP_OUTCOME:-skipped}" \
               "${CONFIG_BACKUP_OUTCOME:-skipped}" "${SECRET_UPDATE_OUTCOME:-skipped}"; do
  [[ "$outcome" == success ]] || problem=1
done
[[ "${HAD_FAILURES:-false}" == true ]] && problem=1

# 没有变动、没有签发错误且整体成功时保持静默，不产生无意义的每日推送。
if [[ -z "$updated" && -z "$failed" && "$problem" -eq 0 ]]; then
  echo "本轮无证书更新、无异常，跳过 Bark 通知。"
  exit 0
fi

csv_count() {
  if [[ -z "$1" ]]; then printf '0'; return; fi
  local commas="${1//[^,]/}"
  printf '%s' "$((${#commas} + 1))"
}

# 将 foo/EC,foo/RSA 归并为简洁的 foo：EC、RSA；始终按真实签发算法展示。
render_pairs() {
  local csv="$1" pair domain algo item
  [[ -n "$csv" ]] || return 0
  local -a items=() order=()
  local -A grouped=()
  IFS=',' read -r -a items <<< "$csv"
  for pair in "${items[@]}"; do
    [[ -n "$pair" ]] || continue
    if [[ "$pair" == invalid-entry ]]; then
      domain="域名清单"
      algo="包含无效条目"
    else
      domain="${pair%/*}"
      algo="${pair##*/}"
    fi
    if [[ -z "${grouped[$domain]+x}" ]]; then
      order+=("$domain")
      grouped["$domain"]="$algo"
    elif [[ ",${grouped[$domain]}," != *",$algo,"* ]]; then
      grouped["$domain"]+="、$algo"
    fi
  done
  for domain in "${order[@]}"; do
    printf '• %s：%s\n' "$domain" "${grouped[$domain]}"
  done
}

updated_count=$(csv_count "$updated")
failed_count=$(csv_count "$failed")
deferred_count=$(csv_count "$deferred")
run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"
time_cn=$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M（北京时间）')

if [[ "${BACKUP_OUTCOME:-skipped}" != success ]]; then
  title="SSL 证书备份异常"
elif [[ "$failed_count" -gt 0 || "${HAD_FAILURES:-false}" == true ]]; then
  title="SSL 续签部分失败"
elif [[ "$problem" -ne 0 ]]; then
  title="SSL 处理完成 · 后续步骤异常"
else
  title="SSL 证书续签成功 · ${updated_count} 张"
fi

body=""
if [[ "$updated_count" -gt 0 ]]; then
  if [[ "${BACKUP_OUTCOME:-skipped}" == success ]]; then
    body="✅ 已签发并备份：${updated_count} 张"
  else
    body="⚠️ 已签发但尚未确认备份：${updated_count} 张"
  fi
  body+=
if [[ "$failed_count" -gt 0 ]]; then
  [[ -z "$body" ]] || body+=$'\n\n'
  body+="❌ 签发失败：${failed_count} 项"
  body+=$'\n'"$(render_pairs "$failed")"
fi
if [[ "$deferred_count" -gt 0 ]]; then
  [[ -z "$body" ]] || body+=$'\n\n'
  body+="⏳ 限额冷却待重试：${deferred_count} 张"
  body+=$'\n'"$(render_pairs "$deferred")"
fi
[[ -z "$body" ]] || body+=$'\n\n'
body+="📋 本轮：${checked} 个域名；发起 ${attempts} 次签发请求"
body+=$'\n'"⏭ 无须更新：${valid_skipped} 张"
if [[ "${BACKUP_OUTCOME:-skipped}" == success ]]; then
  body+=$'\n'"📦 Dropbox：证书备份成功"
else
  body+=$'\n'"⚠️ Dropbox：证书备份失败或未执行"
fi
[[ "${VERIFY_OUTCOME:-skipped}" == success ]] || body+=$'\n'"⚠️ 证书校验未通过或未执行"
[[ "${GUARD_OUTCOME:-skipped}" == success ]] || body+=$'\n'"⚠️ Dropbox 防误删检查未通过或未执行"
[[ "${CONFIG_BACKUP_OUTCOME:-skipped}" == success ]] || body+=$'\n'"⚠️ rclone 配置备份失败或未执行"
[[ "${SECRET_UPDATE_OUTCOME:-skipped}" == success ]] || body+=$'\n'"⚠️ GitHub Secret 更新失败或未执行"
[[ "${RENEW_OUTCOME:-skipped}" == success ]] || body+=$'\n'"⚠️ 续签脚本未正常完成"
body+=$'\n'"🕒 $time_cn"
body+=$'\n'"🔗 点击通知查看 GitHub 运行记录"

payload=$(jq -n --arg title "$title" --arg body "$body" \
  --arg url "$run_url" --arg group "SSL 证书管理" \
  '{title:$title, body:$body, group:$group, url:$url}')

# 不将 BARK_URL（含设备密钥）或完整请求内容打印到 GitHub 日志。
if curl -fsS --max-time 15 -X POST \
  -H 'Content-Type: application/json; charset=utf-8' \
  --data-binary "$payload" "${BARK_URL%/}" >/dev/null; then
  echo "✔ Bark 中文通知已发送（${title}）。"
else
  echo "::warning::Bark 推送失败，不改变原有证书签发或备份结果。"
fi
\n'"$(render_pairs "$updated")"
  if [[ -n "$issuers" ]]; then
    # 汇总真正签发的 CA，不在短信中重复枚举所有证书。
    declare -A ca_count=()
    IFS=',' read -r -a issuer_items <<< "$issuers"
    for issuer_item in "${issuer_items[@]}"; do
      issuer_ca="${issuer_item##*=}"
      ca_count["$issuer_ca"]=$(( ${ca_count[$issuer_ca]:-0} + 1 ))
    done
    body+=
if [[ "$failed_count" -gt 0 ]]; then
  [[ -z "$body" ]] || body+=$'\n\n'
  body+="❌ 签发失败：${failed_count} 项"
  body+=$'\n'"$(render_pairs "$failed")"
fi
if [[ "$deferred_count" -gt 0 ]]; then
  [[ -z "$body" ]] || body+=$'\n\n'
  body+="⏳ 限额冷却待重试：${deferred_count} 张"
  body+=$'\n'"$(render_pairs "$deferred")"
fi
[[ -z "$body" ]] || body+=$'\n\n'
body+="📋 本轮：${checked} 个域名；发起 ${attempts} 次签发请求"
body+=$'\n'"⏭ 无须更新：${valid_skipped} 张"
if [[ "${BACKUP_OUTCOME:-skipped}" == success ]]; then
  body+=$'\n'"📦 Dropbox：证书备份成功"
else
  body+=$'\n'"⚠️ Dropbox：证书备份失败或未执行"
fi
[[ "${VERIFY_OUTCOME:-skipped}" == success ]] || body+=$'\n'"⚠️ 证书校验未通过或未执行"
[[ "${GUARD_OUTCOME:-skipped}" == success ]] || body+=$'\n'"⚠️ Dropbox 防误删检查未通过或未执行"
[[ "${CONFIG_BACKUP_OUTCOME:-skipped}" == success ]] || body+=$'\n'"⚠️ rclone 配置备份失败或未执行"
[[ "${SECRET_UPDATE_OUTCOME:-skipped}" == success ]] || body+=$'\n'"⚠️ GitHub Secret 更新失败或未执行"
[[ "${RENEW_OUTCOME:-skipped}" == success ]] || body+=$'\n'"⚠️ 续签脚本未正常完成"
body+=$'\n'"🕒 $time_cn"
body+=$'\n'"🔗 点击通知查看 GitHub 运行记录"

payload=$(jq -n --arg title "$title" --arg body "$body" \
  --arg url "$run_url" --arg group "SSL 证书管理" \
  '{title:$title, body:$body, group:$group, url:$url}')

# 不将 BARK_URL（含设备密钥）或完整请求内容打印到 GitHub 日志。
if curl -fsS --max-time 15 -X POST \
  -H 'Content-Type: application/json; charset=utf-8' \
  --data-binary "$payload" "${BARK_URL%/}" >/dev/null; then
  echo "✔ Bark 中文通知已发送（${title}）。"
else
  echo "::warning::Bark 推送失败，不改变原有证书签发或备份结果。"
fi
\n'"🏛 签发机构："
    for ca in letsencrypt zerossl google; do
      if (( ${ca_count[$ca]:-0} > 0 )); then
        case "$ca" in
          letsencrypt) label="Let's Encrypt" ;;
          zerossl) label="ZeroSSL" ;;
          google) label="Google Trust Services" ;;
        esac
        body+="$label ${ca_count[$ca]} 张；"
      fi
    done
    body="${body%；}"
  fi
fi
if [[ "$failed_count" -gt 0 ]]; then
  [[ -z "$body" ]] || body+=$'\n\n'
  body+="❌ 签发失败：${failed_count} 项"
  body+=$'\n'"$(render_pairs "$failed")"
fi
if [[ "$deferred_count" -gt 0 ]]; then
  [[ -z "$body" ]] || body+=$'\n\n'
  body+="⏳ 限额冷却待重试：${deferred_count} 张"
  body+=$'\n'"$(render_pairs "$deferred")"
fi
[[ -z "$body" ]] || body+=$'\n\n'
body+="📋 本轮：${checked} 个域名；发起 ${attempts} 次签发请求"
body+=$'\n'"⏭ 无须更新：${valid_skipped} 张"
if [[ "${BACKUP_OUTCOME:-skipped}" == success ]]; then
  body+=$'\n'"📦 Dropbox：证书备份成功"
else
  body+=$'\n'"⚠️ Dropbox：证书备份失败或未执行"
fi
[[ "${VERIFY_OUTCOME:-skipped}" == success ]] || body+=$'\n'"⚠️ 证书校验未通过或未执行"
[[ "${GUARD_OUTCOME:-skipped}" == success ]] || body+=$'\n'"⚠️ Dropbox 防误删检查未通过或未执行"
[[ "${CONFIG_BACKUP_OUTCOME:-skipped}" == success ]] || body+=$'\n'"⚠️ rclone 配置备份失败或未执行"
[[ "${SECRET_UPDATE_OUTCOME:-skipped}" == success ]] || body+=$'\n'"⚠️ GitHub Secret 更新失败或未执行"
[[ "${RENEW_OUTCOME:-skipped}" == success ]] || body+=$'\n'"⚠️ 续签脚本未正常完成"
body+=$'\n'"🕒 $time_cn"
body+=$'\n'"🔗 点击通知查看 GitHub 运行记录"

payload=$(jq -n --arg title "$title" --arg body "$body" \
  --arg url "$run_url" --arg group "SSL 证书管理" \
  '{title:$title, body:$body, group:$group, url:$url}')

# 不将 BARK_URL（含设备密钥）或完整请求内容打印到 GitHub 日志。
if curl -fsS --max-time 15 -X POST \
  -H 'Content-Type: application/json; charset=utf-8' \
  --data-binary "$payload" "${BARK_URL%/}" >/dev/null; then
  echo "✔ Bark 中文通知已发送（${title}）。"
else
  echo "::warning::Bark 推送失败，不改变原有证书签发或备份结果。"
fi
