#!/usr/bin/env bash
set -euo pipefail
: "${EMAIL:?必须配置 EMAIL}"
: "${ACME_PATH:=/home/runner/.acme.sh/acme.sh}"

# Ubuntu 发行版签名包，避免直接执行未校验的远端 rclone 安装脚本。
sudo apt-get update -qq
sudo apt-get install -y -qq rclone

# acme.sh 固定官方 3.1.6 标签，必须匹配审核时确定的提交 SHA。
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git clone -q --depth 1 --branch 3.1.6 https://github.com/acmesh-official/acme.sh.git "$tmp/acme.sh"
[[ "$(git -C "$tmp/acme.sh" rev-parse HEAD)" == 807da6498377ee5e0cf43a78091f46f12dc59a89 ]] || {
  echo "::error::acme.sh 源码版本校验失败。"
  exit 1
}
bash "$tmp/acme.sh/acme.sh" --install --home "$HOME/.acme.sh" --accountemail "$EMAIL" >/dev/null
test -x "$ACME_PATH"
rclone version | head -n 1
"$ACME_PATH" --version
echo "✔ rclone 安装完成，acme.sh 已按固定版本和提交进行校验。"
