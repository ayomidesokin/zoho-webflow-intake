#!/usr/bin/env bash
# Confirm a record (and its picklist values) in Zoho CRM by email. Reads Leads and Contacts.
# Usage: scripts/verify-zoho.sh someone@example.com
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }
: "${ZOHO_CLIENT_ID:?}" "${ZOHO_CLIENT_SECRET:?}" "${ZOHO_REFRESH_TOKEN:?}"
EMAIL="${1:?usage: verify-zoho.sh <email>}"
ACC="${ZOHO_ACCOUNTS_BASE:-https://accounts.zoho.eu}"
API="${ZOHO_API_BASE:-https://www.zohoapis.eu}"

TOKEN="$(curl -fsS "$ACC/oauth/v2/token" \
  -d grant_type=refresh_token -d client_id="$ZOHO_CLIENT_ID" \
  -d client_secret="$ZOHO_CLIENT_SECRET" -d refresh_token="$ZOHO_REFRESH_TOKEN" \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))")"
[ -n "$TOKEN" ] || { echo "token refresh failed"; exit 1; }

FIELDS="id,First_Name,Last_Name,Email,Lead_Status,Plan_for_Sokin,Pipeline,Partner_Status,Lead_Source,Owner"
for MOD in Leads Contacts; do
  echo "=== $MOD :: $EMAIL ==="
  curl -fsS "$API/crm/v6/$MOD/search?criteria=((Email:equals:$EMAIL))&fields=$FIELDS" \
    -H "Authorization: Zoho-oauthtoken $TOKEN" \
    | python3 -c "
import sys,json
d=sys.stdin.read().strip()
if not d:
    print('  (no record)'); sys.exit()
for r in json.loads(d).get('data',[]):
    print('  ', json.dumps(r, ensure_ascii=False))
" || echo "  (no record)"
done
