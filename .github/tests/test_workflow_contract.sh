#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"
echo "Workflow Contract Test 1: GitHub Actions YAML can be parsed"
ruby -e 'require "yaml"; ARGV.each { |f| YAML.parse_file(f) or abort("YAML failed: #{f}") }' \
  .github/workflows/*.yml

echo "Workflow Contract Test 2: Dropbox read/write path and daily cron unchanged"
wf=.github/workflows/generate_and_backup_ssl.yml
grep -Fq 'rclone sync dropbox:$DROPBOX_PATH ./ssl $RCLONE_PARAMS --log-file=rclone_sync.log' "$wf"
grep -Fq 'rclone sync ssl dropbox:$DROPBOX_PATH $RCLONE_PARAMS' "$wf"
grep -Fq 'rclone copy dropbox:$DROPBOX_PATH/cloudflare_domains_list.txt ./' "$wf"
grep -Fq 'cron: "35 23 * * *"' "$wf"
grep -Fq 'permissions:' "$wf"
grep -Fq '  contents: read' "$wf"
[[ "$(grep -c 'uses: actions/checkout@v6' .github/workflows/*.yml | awk -F: '{sum += $2} END {print sum}')" -ge 3 ]]

echo "Workflow Contract Test 3: Cloudflare tokens not exposed during package installation"
! sed -n '/^env:/,/^jobs:/p' "$wf" | grep -Eq 'CF_TOKEN|CF_ACCOUNT_ID'
grep -Fq 'run: bash .github/scripts/install_dependencies.sh' "$wf"
grep -Fq '807da6498377ee5e0cf43a78091f46f12dc59a89' .github/scripts/install_dependencies.sh

echo "Workflow Contract Test 4: safe inventory and Dropbox guard block backup on failure"
grep -Fq 'run: bash .github/scripts/verify_inventory.sh' "$wf"
grep -Fq 'run: bash .github/scripts/guard_dropbox_deletions.sh' "$wf"
grep -Fq 'steps.validate.outputs.had_inventory_gaps' "$wf"
grep -Fq 'steps.renew.outputs.had_critical_deferred' "$wf"

echo "All workflow structure and backup contract checks passed."
