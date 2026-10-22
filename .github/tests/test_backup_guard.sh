#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/ssl/example" "$T/bin"
echo "certificate" > "$T/ssl/example/fullchain.cer"
echo "secret" > "$T/ssl/example/private.key"
cat > "$T/bin/rclone" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == lsf && "$2" == dropbox:SSL && "$3" == -R && "$4" == --files-only ]]
[[ "${MOCK_RCLONE_FAIL:-}" != 1 ]] || exit 99
cat "$MOCK_RCLONE_OUTPUT"
MOCK
chmod +x "$T/bin/rclone"
run_guard() {
  (cd "$T" && PATH="$T/bin:$PATH" MOCK_RCLONE_OUTPUT="$T/remote" \
    bash "$ROOT/.github/scripts/guard_dropbox_deletions.sh")
}
echo "Backup Guard Test 1: identical remote and local files are safe"
printf 'example/fullchain.cer\nexample/private.key\n' > "$T/remote"
run_guard
echo "Backup Guard Test 2: remote-only files must prevent destructive sync"
printf 'example/fullchain.cer\nexample/private.key\noriginal-ca.cer\n' > "$T/remote"
if run_guard; then echo "Remote deletion not blocked"; exit 1; fi
echo "Backup Guard Test 3: remote listing failure must fail closed"
if MOCK_RCLONE_FAIL=1 run_guard; then echo "Listing failure not blocked"; exit 1; fi
echo "All offline Dropbox deletion-guard tests passed."
