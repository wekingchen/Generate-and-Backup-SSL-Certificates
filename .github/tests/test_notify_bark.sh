#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/.github/scripts/notify_bark.sh"
TEMP=$(mktemp -d)
trap 'rm -rf "$TEMP"' EXIT

# 仅本地模拟 curl，不连接 Bark、不使用设备密钥。
cat > "$TEMP/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
payload=""
while (($#)); do
  case "$1" in
    --data-binary)
      payload="$2"
      shift 2 ;;
    *)
      shift ;;
  esac
done
[[ -n "$payload" ]]
printf '%s' "$payload" > "$MOCK_BARK_JSON"
printf '{"code":200}\n'
MOCK
chmod +x "$TEMP/curl"

run_notification() {
  rm -f "$TEMP/request.json"
  env \
    PATH="$TEMP:$PATH" \
    MOCK_BARK_JSON="$TEMP/request.json" \
    BARK_URL="https://bark.example.test/device_key" \
    GITHUB_SERVER_URL="https://github.com" \
    GITHUB_REPOSITORY="example/ssl" \
    GITHUB_RUN_ID="123456" \
    UPDATED_CERTIFICATES="" FAILED_CERTIFICATES="" DEFERRED_CERTIFICATES="" \
    CHECKED_DOMAINS="6" VALID_SKIPPED="10" ISSUE_ATTEMPTS="2" HAD_FAILURES="false" \
    RENEW_OUTCOME="success" VERIFY_OUTCOME="success" GUARD_OUTCOME="success" \
    BACKUP_OUTCOME="success" CONFIG_BACKUP_OUTCOME="success" SECRET_UPDATE_OUTCOME="success" \
    "$@" bash "$SCRIPT"
}

echo "Bark Test 1: two algorithm updates should be grouped, Chinese, backed up and linked"
run_notification UPDATED_CERTIFICATES="443502.xyz/EC,443502.xyz/RSA"
jq -e '
  .title == "SSL 证书续签成功 · 2 张"
  and (.body | contains("443502.xyz：EC、RSA"))
  and (.body | contains("✅ 已签发并备份：2 张"))
  and (.body | contains("📦 Dropbox：证书备份成功"))
  and (.body | contains("⏭ 无须更新：10 张"))
  and (.body | contains("失败：") | not)
  and .group == "SSL 证书管理"
  and .url == "https://github.com/example/ssl/actions/runs/123456"
' "$TEMP/request.json" >/dev/null

echo "Bark Test 2: partial failure should contain affected algorithms and no fake success"
run_notification UPDATED_CERTIFICATES="good.example/EC" \
  FAILED_CERTIFICATES="broken.example/RSA" DEFERRED_CERTIFICATES="cool.example/EC" \
  HAD_FAILURES="true"
jq -e '
  .title == "SSL 续签部分失败"
  and (.body | contains("good.example：EC"))
  and (.body | contains("❌ 签发失败：1 项"))
  and (.body | contains("broken.example：RSA"))
  and (.body | contains("⏳ 限额冷却待重试：1 张"))
  and (.body | contains("cool.example：EC"))
' "$TEMP/request.json" >/dev/null

echo "Bark Test 3: backup failure must never be called backed up"
run_notification UPDATED_CERTIFICATES="good.example/RSA" BACKUP_OUTCOME="failure"
jq -e '
  .title == "SSL 证书备份异常"
  and (.body | contains("已签发但尚未确认备份"))
  and (.body | contains("Dropbox：证书备份失败或未执行"))
  and (.body | contains("已签发并备份") | not)
' "$TEMP/request.json" >/dev/null

echo "Bark Test 4: downstream Secret failure after backup must be explicit"
run_notification UPDATED_CERTIFICATES="good.example/EC" SECRET_UPDATE_OUTCOME="failure"
jq -e '
  .title == "SSL 处理完成 · 后续步骤异常"
  and (.body | contains("Dropbox：证书备份成功"))
  and (.body | contains("GitHub Secret 更新失败或未执行"))
' "$TEMP/request.json" >/dev/null

echo "Bark Test 5: no change and no failure should remain silent"
run_notification
[[ ! -e "$TEMP/request.json" ]]

echo "Bark Test 6: invalid domain list must show meaningful error"
run_notification FAILED_CERTIFICATES="invalid-entry" HAD_FAILURES="true"
jq -e '(.body | contains("域名清单：包含无效条目"))' "$TEMP/request.json" >/dev/null

echo "Bark Test 7: no Bark URL means no notification"
run_notification BARK_URL="" UPDATED_CERTIFICATES="good.example/EC"
[[ ! -e "$TEMP/request.json" ]]

echo "All offline Bark notification tests passed."
