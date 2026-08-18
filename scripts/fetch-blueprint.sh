#!/usr/bin/env bash
# Pull the LIVE blueprint from Make into blueprints/v4-generic-intake.live.json (+ timestamped backup).
# Diff it against blueprints/v4-generic-intake.json to detect drift (e.g. UI dropped picklist fields).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }
: "${MAKE_API_TOKEN:?set MAKE_API_TOKEN in .env}"
SID="${SCENARIO_ID:-9254191}"
BASE="${MAKE_API_BASE:-https://eu2.make.com/api/v2}"
ts="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$ROOT/blueprints/backups"
OUT="$ROOT/blueprints/v4-generic-intake.live.json"

# curl only — urllib/requests get Cloudflare 1010 on this host
curl -fsS -H "Authorization: Token $MAKE_API_TOKEN" "$BASE/scenarios/$SID/blueprint" \
  | python3 -c "import sys,json;print(json.dumps(json.load(sys.stdin)['response']['blueprint'],indent=2,ensure_ascii=False))" \
  > "$OUT"
cp "$OUT" "$ROOT/blueprints/backups/v4-live-$ts.json"
echo "Saved live blueprint -> $OUT"
echo "Backup             -> blueprints/backups/v4-live-$ts.json"
echo "Check for drift    -> diff blueprints/v4-generic-intake.json $OUT"
