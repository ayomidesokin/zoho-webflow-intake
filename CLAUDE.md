# Operating manual — Webflow → Zoho Generic Intake (Make.com)

You are maintaining a Make.com automation that turns **Webflow form submissions into Zoho CRM
leads/contacts**. **This repository is the source of truth.** If the live scenario misbehaves,
`blueprints/v4-generic-intake.json` is the known‑good definition — diagnose against it and, if
needed, restore from it.

Read this file first, then `docs/ARCHITECTURE.md` (how it works) and `docs/RUNBOOK.md`
(symptom → fix). Do not skip the **Invariants** — every past outage came from breaking one.

---

## TL;DR for a repair session
1. Read this file + `docs/ARCHITECTURE.md`.
2. Observe the actual failure — **the DLQ is the only place the real error text lives** (see *Diagnosing*).
3. Edit `blueprints/v4-generic-intake.json` (a plain JSON file). **Never** fix a Zoho module in the Make UI.
4. Deploy with `scripts/deploy-blueprint.sh`; confirm `isinvalid=false`, scenario active, and a test lead lands in Zoho.

---

## The system (resource IDs)

| Thing | Name | ID |
|---|---|---|
| Org / Team / Zone | Sokin / Marketing Ops / eu2 | `3012560` / `2958363` / `eu2` |
| **Intake scenario** | Webflow → Zoho Generic Intake | **`9254191`** |
| Intake trigger webhook | Webflow watch | `4136798` |
| Provisioner scenario | Zoho field provisioner (manual) | `9254449` (hook `4136921`) |
| Data store — form rules | `webflow_zoho_form_config` | `163354` |
| Data store — field rules | `webflow_zoho_field_registry` | `163355` |
| Data store — audit log | `webflow_zoho_submission_log` | `163356` |
| Data store — provisioner log | `zoho_field_provision_log` | `163373` |
| Zoho connection | (Make → Zoho CRM, EU) | `13660469` |
| Webflow connection | (Make → Webflow) | `13316248` |
| Make API base | — | `https://eu2.make.com/api/v2` |
| Zoho API (EU) | — | `accounts.zoho.eu` / `www.zohoapis.eu` |

Secrets are **not** in this repo. Scripts read them from a local, git‑ignored `.env` (see `.env.example`).

---

## INVARIANTS — breaking these fails production *silently*

1. **NEVER open the Zoho "Create/Update an Object" modules (#8, #13, #16) in the Make UI.**
   Their picklist fields are mapped with formulas. A dropdown widget cannot hold a formula, so the
   moment the module is opened and saved, the UI **silently deletes every picklist mapping**
   (Lead_Status, Industry, Plan_for_Sokin, …). Leads keep saving, just with fields missing. All edits
   to these modules go through the blueprint + API only. (Editing routers, filters, and the data‑store
   modules in the UI is fine — just not the three Zoho write modules.)

2. **NEVER remove `metadata.expect` from the Zoho modules.** That array is the per‑field spec the
   connector reads at runtime (`getObjectInsertInput`). Strip it and inserts crash with
   `Cannot read properties of undefined (reading 'spec')`. Make does **not** regenerate it on an API
   push — whatever you send is what runs. `deploy-blueprint.sh` refuses to deploy if it's missing.

3. **Multi‑select picklists need two things** (currently only `Plan_for_Sokin`):
   - mapper = a **bare string that resolves to an array**:
     `{{if(1.data.`checkbox-sokin-plan-input`; split(1.data.`checkbox-sokin-plan-input`; ", "); emptyarray)}}`
     — **not** a literal‑array wrap `["{{split(...)}}"]` (that stores a *stringified* array).
   - a spec entry in `metadata.expect`: `{"name":"Plan_for_Sokin","type":"select","multiple":true}`.
   Without `multiple:true`, the array value crashes the connector.

4. **Don't paste field mappings into the Make formula editor** — it strips backticks and double‑quotes,
   which breaks `` 1.data.`Field name` `` and `get(1.data; "x")`. Edit the JSON blueprint instead.

5. **Every picklist value sent must exist in Zoho** or Zoho rejects the *entire* record (`INVALID_DATA`).
   Match Webflow dropdown options to Zoho's, or enable "Allow other values" on the Zoho field.

---

## Diagnosing (the tooling here is quirky — read this)

- **Execution detail is blind.** `executions_get-detail` and the REST `logs` endpoint return only
  `{"status":"SUCCESS"}` for this org — no per‑module bundles. And handled errors keep the run **green**
  (status 1), so a "successful" run may still have failed a module.
- **The DLQ is where real errors live.** To capture an error, let the failing module run **without an
  `onerror` handler** (or reproduce in a throwaway scenario) with incomplete‑execution storage on, then read:
  `incomplete-executions_list` → `incomplete-executions_get` → the `reason` field has the real message.
- **Verify Zoho writes directly.** Mint a token from the Zoho self‑client creds in `.env` and query CRM:
  `scripts/verify-zoho.sh someone@example.com` (COQL / search). This is how you confirm a fix actually landed.
- **Make API = curl only.** `urllib`/`requests` get Cloudflare‑blocked (HTTP 403 code 1010). Use `curl`.

---

## Fix & deploy loop (safe pattern)

1. `scripts/fetch-blueprint.sh` — pull the current live blueprint (also writes a timestamped backup).
   Diff it against `blueprints/v4-generic-intake.json` to see if the live scenario drifted (e.g. someone
   opened a module in the UI and dropped fields).
2. Edit `blueprints/v4-generic-intake.json` with a JSON‑safe editor (or a Python patch script). Keep
   `metadata.expect` intact; keep the multi‑select rules above.
3. **Prove the fix in isolation before touching production.** Create a throwaway scenario (webhook →
   one `zohocrm:createObject` copied from #16, `onerror` off, DLQ on), fire a test payload, confirm the
   lead + field values in Zoho, then delete the throwaway scenario/hook and any test leads. This is how
   the Plan_for_Sokin fix was verified — see `docs/RUNBOOK.md`.
4. `scripts/deploy-blueprint.sh` — backs up live, PATCHes the blueprint, checks `isinvalid=false`, and
   re‑activates. Then run `verify-zoho.sh` on a fresh test submission.

**To restore after a UI‑corruption incident:** `scripts/deploy-blueprint.sh` re‑pushes this repo's
blueprint wholesale, which puts the correct mappers + `metadata.expect` back. That is the entire point
of keeping this file under version control.

---

## Scope notes / known soft spots
- Module **#8 updates Contacts** (not Leads); #13/#16 are Leads. #8 currently carries the Leads‑derived
  `metadata.expect` — harmless for shared fields, but if a form sends a Lead‑only field to an existing
  Contact, Zoho may reject it. The Contact‑update path is the least‑tested branch.
- The Zoho write modules do **not** set `trigger:["workflow","approval","blueprint"]`, so Zoho workflow/
  assignment automations may not fire for records written here (every other Sokin form scenario sets it).
  Adding it is a safe, recommended change — see RUNBOOK.
- Bigger structural fix (optional): replace the typed `createObject`/`updateObject` modules with raw
  `zohocrm:makeApiCall` (JSON body). That removes invariants #1–#3 entirely (no field widgets, no
  `metadata.expect`). See RUNBOOK → "Hardening options".
