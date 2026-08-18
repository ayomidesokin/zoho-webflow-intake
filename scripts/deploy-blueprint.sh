#!/usr/bin/env bash
# Deploy blueprints/v4-generic-intake.json to the live scenario (restore source of truth).
# Refuses to deploy if the Zoho write modules lost metadata.expect or Plan_for_Sokin multiple:true.
# Backs up the current live blueprint first. Set CONFIRM=1 to skip the prompt.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }
: "${MAKE_API_TOKEN:?set MAKE_API_TOKEN in .env}"
SID="${SCENARIO_ID:-9254191}"
BASE="${MAKE_API_BASE:-https://eu2.make.com/api/v2}"
BP="$ROOT/blueprints/v4-generic-intake.json"

# 1) safety guard — enforce the invariants before pushing
python3 - "$BP" <<'PY'
import sys,json
bp=json.load(open(sys.argv[1]))
mods={}
def walk(f):
    for m in f:
        mods[m['id']]=m
        for r in m.get('routes',[]) or []: walk(r.get('flow',[]))
walk(bp['flow'])
for i in (8,13,16):
    exp=(mods.get(i,{}).get('metadata') or {}).get('expect')
    assert exp, f"REFUSING: module {i} has no metadata.expect (Invariant #2)"
    pfs=[f for f in exp if f.get('name')=='Plan_for_Sokin']
    assert pfs and pfs[0].get('multiple') is True, f"REFUSING: module {i} Plan_for_Sokin not multiple:true (Invariant #3)"
print("guard OK — metadata.expect present; Plan_for_Sokin multiple:true on #8/#13/#16")
PY

# 2) confirm
if [ "${CONFIRM:-}" != "1" ]; then
  read -r -p "Deploy $BP to scenario $SID (overwrites live)? [y/N] " a
  [ "$a" = "y" ] || { echo "aborted"; exit 1; }
fi

# 3) back up current live first
"$ROOT/scripts/fetch-blueprint.sh" >/dev/null && echo "backed up current live"

# 4) push (blueprint value must be a stringified JSON)
body="$(python3 -c "import json,sys;print(json.dumps({'blueprint':open(sys.argv[1]).read()}))" "$BP")"
curl -fsS -X PATCH "$BASE/scenarios/$SID" \
  -H "Authorization: Token $MAKE_API_TOKEN" -H "Content-Type: application/json" -d "$body" \
  | python3 -c "import sys,json;s=json.load(sys.stdin).get('scenario',{});print('deployed -> isinvalid:',s.get('isinvalid'),'| isActive:',s.get('isActive'))"

# 5) ensure active (no-op if already running)
curl -fsS -X POST "$BASE/scenarios/$SID/start" -H "Authorization: Token $MAKE_API_TOKEN" >/dev/null 2>&1 || true
echo "Done. Send a test submission, then: scripts/verify-zoho.sh <email>"
