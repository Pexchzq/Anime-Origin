#!/usr/bin/env bash
# Syntax- and lint-check every controller with the real Luau parser.
#
#   Tests/check_syntax.sh            # all production files
#   Tests/check_syntax.sh main.lua   # just one
#   Tests/check_syntax.sh --raw      # keep the unknown-global noise too
#
# Roblox engine globals (game, task, workspace...) and the executor API
# (writefile, getgc...) do not exist in luau-analyze's environment, so those
# "Unknown global"/"Unknown type" lines are filtered out. Everything else --
# syntax errors, dead functions, misleading expressions -- is a real finding.
#
# Requires: brew install luau
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v luau-analyze >/dev/null 2>&1; then
    echo "luau-analyze not found. Install it with:  brew install luau" >&2
    exit 127
fi

RAW=0
if [ "${1:-}" = "--raw" ]; then RAW=1; shift; fi

KNOWN_GLOBALS='game|task|workspace|script|warn|settings|writefile|appendfile|readfile|isfile|delfile|listfiles|makefolder|isfolder|delfolder|getgc|getgenv|getrawmetatable|setreadonly|checkcaller|newcclosure|hookfunction|hookmetamethod|getnamecallmethod|getconnections|setfpscap|setclipboard|queue_on_teleport|request|syn|fluxus|Enum|Vector3|CFrame|Instance|Color3|UDim2|Ray'

if [ "$#" -gt 0 ]; then
    FILES=("$@")
else
    FILES=(Loader.lua Config.lua FastMode.lua InGameSettings.lua \
           UnitProgression.lua main.lua AutoPlay.lua Optimizer.lua logstats.lua)
fi

cd "$ROOT"
status=0
for file in "${FILES[@]}"; do
    output="$(luau-analyze --mode=nonstrict "$file" 2>&1)"
    if [ "$RAW" -eq 0 ]; then
        output="$(printf '%s\n' "$output" \
            | grep -vE "Unknown global '($KNOWN_GLOBALS)'" \
            | grep -vE "Unknown type '($KNOWN_GLOBALS)'" )"
    fi
    output="$(printf '%s\n' "$output" | grep -E '^[^ ]+\.lua\(' || true)"
    count="$(printf '%s' "$output" | grep -c . || true)"
    if [ "$count" -eq 0 ]; then
        printf '  OK    %s\n' "$file"
    else
        printf '  WARN  %s (%s finding(s))\n' "$file" "$count"
        printf '%s\n' "$output" | sed 's/^/        /'
        if printf '%s' "$output" | grep -q 'SyntaxError'; then status=1; fi
    fi
done

exit "$status"
