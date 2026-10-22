#!/usr/bin/env bash
set -euo pipefail
: "${DROPBOX_PATH:=SSL}"
[[ -d ssl ]] || { echo "::error::本地证书目录不存在，阻止 Dropbox 同步。"; exit 1; }

# 读取 Dropbox 远端列表并与本地对比，任何远端文件可能被删除即拒绝回写。
# 保留原 rclone lsf 参数、根目录和排序规则。
remote=$(mktemp)
local_files=$(mktemp)
would_delete=$(mktemp)
trap 'rm -f "$remote" "$local_files" "$would_delete"' EXIT
rclone lsf "dropbox:$DROPBOX_PATH" -R --files-only | LC_ALL=C sort > "$remote"
(cd ssl && find . -type f -printf '%P\n' | LC_ALL=C sort) > "$local_files"
comm -23 "$remote" "$local_files" > "$would_delete"
if [[ -s "$would_delete" ]]; then
  echo "::error::Dropbox 中存在本地缺少的文件，已阻止可能造成远端删除的同步。"
  echo "待保护文件数：$(wc -l < "$would_delete")"
  exit 1
fi
echo "✔ Dropbox 远端文件列表与本地副本一致，允许进入备份步骤。"
