#!/bin/bash
# Publishes the committed Spending Analysis web page to K3JDR-DSKTOP-11 (part of releasing MxAcctMGR).
#
#   Services/spending-web/publish-to-pc.sh             # publish HEAD
#   Services/spending-web/publish-to-pc.sh --dry-run   # only say what would change
#   Services/spending-web/publish-to-pc.sh --ref <commit> --host <ssh host>
#
# Exports the page's files from git (only what is committed goes out), compares them with the PC's copies by SHA-256,
# copies the ones that differ to C:\Users\calla\MxServices\Services\ (the repository's layout), and restarts the task
# "Spending Analysis web page" when server code changed (the page's own files need only a browser reload). Then it asks
# the server on the PC itself for /api/setup with the PC's key, so the key never leaves the PC, and records the commit
# it published in published.txt there. It never touches the PC's spending_web.local.json (key and password): the link
# stays the same through every publish, and the script checks that the config is byte-for-byte unchanged afterwards.
# Only the user changes the link (see README, "The link").
set -euo pipefail

HOST=${SPENDING_WEB_HOST:-k3jdr-dsktop-11}
REF=HEAD
DRY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY=1 ;;
        --ref) REF=$2; shift ;;
        --host) HOST=$2; shift ;;
        -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
REMOTE_ROOT='C:\Users\calla\MxServices'
FILES=(
    Services/spending-web/spending_web.py
    Services/spending-web/spending_web.example.json
    Services/spending-web/install-on-windows.ps1
    Services/spending-web/static/index.html
    Services/spending-web/static/app.js
    Services/spending-web/static/app.css
    Services/accounts/spending.py
    Services/accounts/bank.py
)
COMMIT=$(git -C "$ROOT" rev-parse --short "$REF")
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST")

if ! git -C "$ROOT" diff --quiet HEAD -- "${FILES[@]}"; then
    echo "Note: uncommitted changes in these files are not published (only $REF is):"
    git -C "$ROOT" diff --stat HEAD -- "${FILES[@]}" | sed 's/^/  /'
fi

CONFIG_HASH="(Get-FileHash -Algorithm SHA256 '$REMOTE_ROOT\\Services\\spending-web\\spending_web.local.json').Hash"
LINK_BEFORE=$("${SSH[@]}" "$CONFIG_HASH" | tr -d '\r')

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
git -C "$ROOT" archive "$REF" "${FILES[@]}" | tar -x -C "$TMP"

# The PC's copies of these files: "relative/path SHA256" for each, and the commit published last.
LIST=$(printf "'%s'," "${FILES[@]}")
"${SSH[@]}" "foreach (\$r in @(${LIST%,})) { \$p = Join-Path '$REMOTE_ROOT' \$r.Replace('/', '\\'); if (Test-Path \$p) { \$r + ' ' + (Get-FileHash -Algorithm SHA256 \$p).Hash } }; if (Test-Path '$REMOTE_ROOT\\Services\\spending-web\\published.txt') { 'published ' + (Get-Content '$REMOTE_ROOT\\Services\\spending-web\\published.txt' -Raw).Trim() }" \
    | tr -d '\r' > "$TMP/remote.txt"
echo "On $HOST: $(grep '^published ' "$TMP/remote.txt" | cut -d' ' -f2- || echo 'no record of a published commit')"

CHANGED=()
for f in "${FILES[@]}"; do
    local_hash=$(shasum -a 256 "$TMP/$f" | cut -d' ' -f1 | tr 'a-f' 'A-F')
    remote_hash=$(awk -v p="$f" '$1 == p { print $2 }' "$TMP/remote.txt")
    [ "$local_hash" = "$remote_hash" ] || CHANGED+=("$f")
done

if [ ${#CHANGED[@]} -eq 0 ]; then
    echo "Nothing to publish: the PC already has $COMMIT's files."
else
    echo "To publish from $COMMIT:"
    printf '  %s\n' "${CHANGED[@]}"
fi
[ $DRY -eq 1 ] && exit 0

RESTART=0
# (macOS's bash 3.2 calls an empty array unbound under set -u: loop only when there is something to copy.)
if [ ${#CHANGED[@]} -gt 0 ]; then
    for f in "${CHANGED[@]}"; do
        dir=$(dirname "$f")
        "${SSH[@]}" "New-Item -ItemType Directory -Force '$REMOTE_ROOT\\${dir//\//\\}' | Out-Null"
        scp -q -o BatchMode=yes "$TMP/$f" "$HOST:${REMOTE_ROOT//\\//}/$f"
        case "$f" in *.py) RESTART=1 ;; esac
    done
fi

if [ $RESTART -eq 1 ]; then
    echo "Server code changed: restarting the task."
    "${SSH[@]}" "Stop-ScheduledTask -TaskName 'Spending Analysis web page'; Start-Sleep -Seconds 1; Start-ScheduledTask -TaskName 'Spending Analysis web page'"
fi

# The server on the PC answers its own API with the PC's key (the key stays there).
STATUS=$("${SSH[@]}" "Start-Sleep -Seconds 2; \$c = Get-Content '$REMOTE_ROOT\\Services\\spending-web\\spending_web.local.json' -Raw | ConvertFrom-Json; \$p = if (\$c.port) { \$c.port } else { 8780 }; try { (Invoke-WebRequest -UseBasicParsing -TimeoutSec 30 ('http://127.0.0.1:' + \$p + '/s/' + \$c.key + '/api/setup')).StatusCode } catch { 'failed: ' + \$_.Exception.Message }" | tr -d '\r')
if [ "$STATUS" != "200" ]; then
    echo "The page doesn't answer on $HOST ($STATUS). Its log: $REMOTE_ROOT\\Services\\spending-web\\spending_web.log" >&2
    exit 1
fi
"${SSH[@]}" "Set-Content -Path '$REMOTE_ROOT\\Services\\spending-web\\published.txt' -Value '$COMMIT $(date '+%Y-%m-%d %H:%M')'"
LINK_AFTER=$("${SSH[@]}" "$CONFIG_HASH" | tr -d '\r')
if [ "$LINK_BEFORE" != "$LINK_AFTER" ]; then
    echo "The link config on $HOST changed during the publish: check spending_web.local.json before telling anyone." >&2
    exit 1
fi
echo "Published $COMMIT to $HOST: the page answers, and the link is unchanged."
