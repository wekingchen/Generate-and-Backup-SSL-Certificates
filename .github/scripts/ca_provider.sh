#!/usr/bin/env bash
# 在 renew_certificates.sh 中 source；本文件只负责 CA 选择、注册和失败分类。
# 不在 GitHub 日志中回显 EAB 凭证，也不向 Dropbox 新增 ACME 账户文件。

ssl_ca_init() {
  SSL_CA_MODE="${SSL_CA_MODE:-auto}"
  SSL_FALLBACK_CA="${SSL_FALLBACK_CA:-off}"
  case "$SSL_CA_MODE" in auto|letsencrypt|zerossl|google) ;; *)
    echo "::error::不支持的证书机构选项：$SSL_CA_MODE"
    return 1 ;;
  esac
  case "$SSL_FALLBACK_CA" in off|zerossl) ;; *)
    echo "::error::备用 CA 仅支持 off 或 zerossl。"
    return 1 ;;
  esac
  if [[ "$SSL_CA_MODE" == auto ]]; then
    SSL_PRIMARY_CA=letsencrypt
  else
    SSL_PRIMARY_CA="$SSL_CA_MODE"
  fi
  if [[ "$SSL_CA_MODE" == google && "${GITHUB_EVENT_NAME:-}" == schedule ]]; then
    echo "::error::Google Public CA 只支持手动选择，避免一次性 EAB 被每日 Runner 重复消耗。"
    return 1
  fi
  declare -gA SSL_CA_REGISTERED=()
  echo "✔ 主签发机构：$SSL_PRIMARY_CA；备用：$([[ "$SSL_CA_MODE" == auto ]] && echo "$SSL_FALLBACK_CA" || echo off)"
}

# ZeroSSL 的 EAB 可复用；Google Public CA 的 EAB 只能用于创建一次账户。
# GitHub 执行器是临时的；Google 仅供单次受控试验，不能将其视作已实现长期自动续签。
ssl_ca_register() {
  local ca="$1" kid hmac logfile
  case "$ca" in
    letsencrypt) return 0 ;;
    zerossl)
      kid="${ZEROSSL_EAB_KID:-}"
      hmac="${ZEROSSL_EAB_HMAC_KEY:-}"
      ;;
    google)
      kid="${GOOGLE_EAB_KID:-}"
      hmac="${GOOGLE_EAB_HMAC_KEY:-}"
      ;;
    *)
      echo "::error::未知 CA：$ca"
      return 1 ;;
  esac
  if [[ -n "${SSL_CA_REGISTERED[$ca]+x}" ]]; then
    return 0
  fi
  if [[ -z "$kid" || -z "$hmac" ]]; then
    echo "::warning::$ca 缺少 EAB 凭证，拒绝向该 CA 提交签发请求。"
    return 1
  fi
  logfile=$(mktemp)
  if "$ACME_PATH" --register-account --server "$ca" -m "${EMAIL:-}" \
    --eab-kid "$kid" --eab-hmac-key "$hmac" >"$logfile" 2>&1; then
    SSL_CA_REGISTERED["$ca"]=1
    rm -f "$logfile"
    echo "✔ $ca ACME 账户准备完成。"
    return 0
  fi
  # 注册错误可能包含账户凭据，因此只显示抽象原因，不公开完整日志。
  rm -f "$logfile"
  echo "::warning::$ca ACME 账户注册失败；请检查 EAB 凭证、有效期和账号使用状态。"
  return 1
}

# 只针对 CA 服务侧暂时不可用的典型 5xx 错误开启备用，不对 429、
# DNS-01/CAA 验证失败、无凭证或一般未分类错误自动跨 CA 重试。
ssl_ca_transient_error() {
  local log="$1"
  [[ -s "$log" ]] || return 1
  if grep -Eiq '429|rate.?limit|too many certificates|Retry-After|CAA|dns_cf|dns-01|unauthorized|invalid response' "$log"; then
    return 1
  fi
  grep -Eiq 'HTTP([/ ]+[0-9.]+)?[ :]+50[0234]|HTTP[ :]+5[0-9]{2}|status[ :]+5[0-9]{2}|502 Bad Gateway|503 Service Unavailable|504 Gateway Timeout' "$log"
}
