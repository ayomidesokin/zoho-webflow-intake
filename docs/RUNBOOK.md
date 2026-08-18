# Runbook — diagnosing & fixing the intake scenario

Read `../CLAUDE.md` (Invariants + Diagnosing) first. All commands assume `.env` is populated and you
run scripts from the repo root.

## Golden diagnostic order
1. **Did it even match a form?** Check `webflow_zoho_submission_log` (`163356`) for a row for that email.
   `no_config` = the config gate rejected it (see F4). No row at all = trigger/earlier failure.
2. **What's the real error?** Check the DLQ — that's the only place the message lives:
   `incomplete-executions_list {scenarioId:9254191}` → `incomplete-executions_get {id}` → `reason`.
   (Execution detail returns only `{"status":"SUCCESS"}`; handled errors show as green runs.)
3. **Did the write land?** `scripts/verify-zoho.sh <email>` — reads the record + its picklist values.

---

## F1 — Leads created but picklist fields are missing / blank
**Cause:** someone opened Zoho module #8/#13/#16 in the Make UI and saved → the UI silently dropped the
picklist mappings (Invariant #1).
**Confirm:** `scripts/fetch-blueprint.sh` then diff against `blueprints/v4-generic-intake.json` — the live
module's `mapper` will have fewer keys.
**Fix:** restore from source of truth → `scripts/deploy-blueprint.sh`. Re‑test. Tell whoever opened it to
never open those three modules in the UI.

## F2 — `Function 'getObjectInsertInput' finished with error! Cannot read properties of undefined (reading 'spec')`
**Cause:** a Zoho write module lost its `metadata.expect`, or a multi‑select field there is missing
`multiple:true`. An array‑valued field (Plan_for_Sokin) then reads an undefined spec (Invariant #2/#3).
**Confirm:**
```bash
python3 -c "import json;bp=json.load(open('blueprints/v4-generic-intake.json'));
m={x['id']:x for f in [bp['flow']] for x in __import__('itertools').chain.from_iterable([[n] for n in _walk(f)])}"  # or just eyeball metadata.expect on #8/#13/#16
```
Simpler: open the JSON and check each of #8/#13/#16 has `metadata.expect` (≈91 entries) including
`{"name":"Plan_for_Sokin","type":"select","multiple":true}`.
**Fix:** ensure the spec is present (this repo's blueprint already has it) and `deploy-blueprint.sh`.
Keep the mapper as the bare‑string `split(...)` form, **never** `["{{split(...)}}"]`.
**History:** this was the 2026‑08 outage. Root cause = earlier pushes had stripped `metadata.expect`.
Verified fix by cloning #16 into a throwaway scenario, firing a 2‑value payload, and confirming Zoho stored
`["Receive money from your customers","Pay suppliers or contractors"]`.

## F3 — `INVALID_DATA` from Zoho on a picklist field
**Cause:** the value sent isn't one of that field's Zoho options (Invariant #5). Zoho rejects the whole record.
**Confirm:** DLQ `reason` names the field; compare the sent value to Zoho's option list
(`ExpectModuleCreate` RPC, or Zoho Setup → the field).
**Fix:** align the Webflow option to Zoho's exact string, add the option in Zoho, or enable "Allow other
values" on the field. Multi‑select values are case/spacing sensitive.

## F4 — Submissions logged as `no_config` (nothing written to Zoho)
**Cause:** no active `form_config` row matched. Matching compares the hidden **"Campaign name"** value
(fallback: form name `{{1.name}}`) against each row's `match` array; the row must have `active = true`.
**Fix:** in `form_config` (`163354`), add the value to the right row's `match`, or set `active = true`.
Data‑store filter format is a flat array `[[{a,o,b}]]`; records are nested under `.data.`.

## F5 — No submission row at all / trigger not firing
**Cause:** Webflow watch (#1) or its connection/webhook. **Fix:** confirm the scenario is **active**, the
Webflow connection (`13316248`) is valid, and the form actually posts. Check `executions_list`.

## F6 — Contact‑update path errors (least‑tested branch)
**Cause:** #8 targets **Contacts** but carries a Leads‑derived `metadata.expect`; a Lead‑only field
(e.g. Plan_for_Sokin if Contacts lacks it) sent to an existing Contact can be rejected.
**Fix:** if this bites, either drop the offending field from #8's mapper, or build a Contacts‑specific
`metadata.expect` for #8 (from the `ExpectModuleUpdate` RPC on module = Contacts).

---

## Hardening options (recommended for long‑term ownership)

1. **Add Zoho automation triggers.** Add `"trigger": ["workflow","approval","blueprint"]` to the mappers of
   #8/#13/#16 so Zoho workflow/assignment rules fire (every other Sokin form scenario sets this; this one
   doesn't). Low risk, but it does start firing Zoho automations — deploy during a quiet window.

2. **Replace typed writes with raw API calls (removes the whole fragility class).** Swap
   `zohocrm:createObject`/`updateObject` for `zohocrm:makeApiCall` posting a JSON body to
   `/crm/v3/Leads` (or `/crm/v3/Leads/upsert` with `duplicate_check_fields:["Email"]`, which can also
   collapse the search→router→create/update chain). A `makeApiCall` module has **no field widgets**, so
   Invariant #1 (UI deletes picklists) and #2 (`metadata.expect`) simply don't apply, and multi‑select is
   just a JSON array. Trade‑off: you hand‑maintain the JSON body and add an explicit success/error check
   on the response. Prove it in a throwaway scenario first (F2 pattern), then cut over one module at a time.

3. **Add failure alerting.** Handled errors keep runs green and hide in the DLQ. Add an error handler that
   posts to Slack/email on write failure, or a scheduled check of `incomplete-executions_list`.

## Reference: how the fix loop was run (reproducible)
- Fetch/deploy blueprint: `scripts/fetch-blueprint.sh`, `scripts/deploy-blueprint.sh` (curl; urllib is CF‑blocked).
- Capture real errors: fail a module with `onerror` off + `metadata.scenario.dlq:true`, read `incomplete-executions_get`.
- Verify in Zoho: `scripts/verify-zoho.sh <email>` (self‑client OAuth, EU DC).
- Always test in a throwaway scenario before touching `9254191`; delete test scenario/hook/leads after.
