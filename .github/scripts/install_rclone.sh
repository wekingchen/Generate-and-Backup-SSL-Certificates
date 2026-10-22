#!/usr/bin/env bash
set -euo pipefail
# 固定 rclone 1.75.2 官方 GitHub Release，按发布资产 SHA-256 校验。
# 不执行任何远程 shell 安装脚本，避免老旧发行版软件包。
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
url="https://github.com/rclone/rclone/releases/download/v1.75.2/rclone-v1.75.2-linux-amd64.zip"
curl -fsSL --retry 3 --connect-timeout 15 --max-time 180 "$url" -o "$tmp/rclone.zip"
echo "349ac8fba6ff65d6247043f1750cdcb518ec5d500ef91463a10d37c0ccdf3702  $tmp/rclone.zip" | sha256sum -c - >/dev/null
unzip -q "$tmp/rclone.zip" -d "$tmp"
sudo install -m 0755 "$tmp/rclone-v1.75.2-linux-amd64/rclone" /usr/local/bin/rclone
[[ "$(rclone version | head -n 1)" == "rclone v1.75.2" ]] || {
  echo "::error::rclone 安装后的版本不匹配。"
  exit 1
}
echo "✔ rclone 1.75.2 官方发布文件 SHA-256 校验通过。"
