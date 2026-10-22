#!/usr/bin/env bash
set -euo pipefail
: "${EMAIL:?必须配置 EMAIL}"
: "${ACME_PATH:=/home/runner/.acme.sh/acme.sh}"

# 固定 rclone 的独立安装和 SHA-256 校验，与证书到期检查共用。
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
bash "$ROOT/.github/scripts/install_rclone.sh"

# acme.sh 固定官方 3.1.6 标签，必须匹配审核时确定的提交 SHA。
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git clone -q --depth 1 --branch 3.1.6 https://github.com/acmesh-official/acme.sh.git "$tmp/acme.sh"
[[ "$(git -C "$tmp/acme.sh" rev-parse HEAD)" == 807da6498377ee5e0cf43a78091f46f12dc59a89 ]] || {
  echo "::error::acme.sh 源码版本校验失败。"
  exit 1
}
(cd "$tmp/acme.sh" && bash ./acme.sh --install --home "$HOME/.acme.sh" --accountemail "$EMAIL" >/dev/null)
test -x "$ACME_PATH"
rclone version | head -n 1
"$ACME_PATH" --version
echo "✔ rclone 安装完成，acme.sh 已按固定版本和提交进行校验。"
