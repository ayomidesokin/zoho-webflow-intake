# Architecture — Webflow → Zoho Generic Intake

One Make scenario (`9254191`) handles **every** Webflow lead form. It identifies the form from a
Data Store config row, finds‑or‑creates the person in Zoho, attaches a campaign, and logs every
submission. Adding a new form = add a config row (+ any new fields to the registry, then run the
provisioner) — **no new scenario, no new modules.**

```
Webflow form submitted
      │  {{1.name}} = form name, {{1.data.*}} = field values (incl. hidden "Campaign name")
      ▼
 [1] Webflow watch  →  [2] set submission_id ({{uuid}})
      ▼
 [3] Search form_config  (match the hidden "Campaign name", fallback to form name)
      ▼
 [4] Router — config found & active?
      ├─ NO  → [5] log `no_config`  (STOP; nothing written to Zoho)
      └─ YES → [6] Search Zoho CONTACTS by email
                    ▼
               [7] Router — contact found?
                    ├─ YES → [8] Update CONTACT → [9] attach campaign → [10] log `contact_update`
                    └─ NO  → [11] Search Zoho LEADS by email
                                  ▼
                             [12] Router — lead found?
                                  ├─ YES → [13] Update LEAD → [14] attach campaign → [15] log `lead_update`
                                  └─ NO  → [16] Create LEAD → [17] attach campaign → [18] log `lead_create`
```

Net behaviour: existing people are updated (never duplicated), new people become Leads, and every
submission leaves an audit row.

## Module map

| # | Module | Purpose | Filter (when it runs) |
|---|---|---|---|
| 1 | `webflow:watchSites` | Trigger — form submission | — |
| 2 | `util:SetVariable2` | `submission_id = {{uuid}}` (roundtrip scope) | — |
| 3 | `datastore:SearchRecord` | Look up `form_config` (store `163354`, limit 1, continue if none) | — |
| 4 | `builtin:BasicRouter` | Config gate | — |
| 5 | `datastore:AddRecord` | Log `no_config` and stop | `{{3.data.active}}` **≠** `true` |
| 6 | `zohocrm:searchObjects` | Search **Contacts** by email | `{{3.data.form_key}}` exists AND `{{3.data.active}}` = `true` |
| 7 | `builtin:BasicRouter` | Contact found? | — |
| 8 | `zohocrm:updateObject` **(Contacts)** | Update the Contact | `{{6.id}}` exists |
| 9 | `zohocrm:updateRelatedRecord` | Attach campaign to Contact | campaign id present |
| 10 | `datastore:AddRecord` | Log `contact_update` | — |
| 11 | `zohocrm:searchObjects` | Search **Leads** by email | `{{6.id}}` does **not** exist |
| 12 | `builtin:BasicRouter` | Lead found? | — |
| 13 | `zohocrm:updateObject` **(Leads)** | Update the Lead | `{{11.id}}` exists |
| 14 | `zohocrm:updateRelatedRecord` | Attach campaign to Lead | campaign id present |
| 15 | `datastore:AddRecord` | Log `lead_update` | — |
| 16 | `zohocrm:createObject` **(Leads)** | Create a new Lead | `{{11.id}}` does **not** exist |
| 17 | `zohocrm:updateRelatedRecord` | Attach campaign to new Lead | campaign id present |
| 18 | `datastore:AddRecord` | Log `lead_create` | — |

> The three **bold** Zoho write modules (#8, #13, #16) are the fragile ones — see INVARIANTS in `../CLAUDE.md`.
> `searchObjects` output id is lowercase `{{6.id}}` / `{{11.id}}`; `createObject` output id is **capital** `{{16.Id}}`.

## How fields get mapped (the union mapper)

The write modules use one **superset mapper** — it lists every field any form could send. Each field
pulls its value with `ifempty()` over the possible Webflow aliases, e.g.:

```
First_Name       = {{ifempty(1.data.`First name`; 1.data.first_name; 1.data.name)}}
Company          = {{ifempty(1.data.Company; 1.data.`Company Name`; 1.data.company)}}
Plan_for_Sokin   = {{if(1.data.`checkbox-sokin-plan-input`; split(1.data.`checkbox-sokin-plan-input`; ", "); emptyarray)}}
```

If a form doesn't send a field, its value is empty and Zoho skips it (Send Null = off). That's why one
scenario serves every form even though each sends a different slice of fields.

Per‑form values come from the matched **config row**, not from code:

| Written field | Source |
|---|---|
| Lead Source | payload `Lead Source` → else `form_config.lead_source` |
| Lead Status | `form_config.lead_status` |
| Owner | payload `Zoho Lead Owner ID` → else `form_config.owner_id` → else `owner_id_source` field |
| Campaign attached | payload `Zoho Campaign ID` → else `form_config.campaign_id` / `campaign_id_source` (only fires if present) |
| Extra static fields | `form_config.extra_static_fields` (e.g. `Pipeline`, `Partner_Status` for partner leads) |

## Data model

**`webflow_zoho_form_config`** (`163354`) — one row per form:
`form_key` (pk), `match` (array of names/values compared to the hidden "Campaign name"),
`lead_source`, `lead_status`, `owner_id`, `owner_id_source`, `campaign_id`, `campaign_id_source`,
`extra_static_fields` (nested: `Partner_Status`, `Pipeline`), `active` (true/false).

**`webflow_zoho_field_registry`** (`163355`) — one row per field:
`canonical_field` (pk), `zoho_api_name`, `zoho_type`, `source_aliases`, `bucket` (`core`/`approved_custom`),
`auto_create`, `pick_list_values`, `active`. Consumed by the **provisioner** (`9254449`), which creates
missing text fields in Zoho and logs to `zoho_field_provision_log` (`163373`).

**`webflow_zoho_submission_log`** (`163356`) — one row per submission: `submission_id`, `form_name`,
`form_key`, `email`, payload, Zoho module + record id, `action`
(`no_config` / `contact_update` / `lead_update` / `lead_create`), `status`.

## Adding a new form (normal path)
1. Give the Webflow form a hidden **`Campaign name`** field with a stable value.
2. Add a `form_config` row: `match` contains that value, set `lead_source`/`lead_status`/owner/campaign,
   `active = true`. Put partner routing (`Pipeline`, `Partner_Status`) in `extra_static_fields`.
3. If the form introduces **new Zoho fields**, add them to `field_registry` and run the provisioner.
4. Submit the form; confirm with `scripts/verify-zoho.sh <email>`.
