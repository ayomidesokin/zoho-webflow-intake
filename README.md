# Webflow → Zoho CRM intake (Make.com) — source of truth

This repo is the **authoritative definition** of the Make.com scenario that turns Webflow lead‑form
submissions into Zoho CRM leads/contacts (scenario `9254191`, "Webflow → Zoho Generic Intake", zone `eu2`).

If the live scenario breaks, this repo tells you (or an AI) how it's *supposed* to work and how to
restore it. The live scenario is fragile to edit in the Make UI — the blueprint here is the safe way
to change it.

## Repo map
```
CLAUDE.md                        ← START HERE. Operating manual + invariants + fix/deploy loop.
docs/ARCHITECTURE.md             How it works: flow diagram, module map, field mapping, data model.
docs/RUNBOOK.md                  Symptom → cause → fix for every known failure mode.
blueprints/v4-generic-intake.json  The known-good blueprint. Re-importable into Make.
scripts/fetch-blueprint.sh       Pull the live blueprint from Make (curl).
scripts/deploy-blueprint.sh      Restore/deploy this blueprint to Make (backs up live first).
scripts/verify-zoho.sh <email>   Confirm a record + its fields in Zoho CRM.
.env.example                     Copy to .env (git-ignored) and fill in tokens.
```

## For an AI assistant picking this up
Read `CLAUDE.md` in full, then `docs/ARCHITECTURE.md`. The three hard rules that prevent silent
data loss are the **Invariants** in `CLAUDE.md` — do not edit the Zoho write modules in the Make UI,
do not strip `metadata.expect`, and keep the multi‑select mapper as a bare‑string `split(...)`.
Diagnose errors through the DLQ (`incomplete-executions_get`), not the execution log.

## First‑time setup
```bash
cp .env.example .env      # then paste your Make API token + Zoho self-client creds
```
`.env` is git‑ignored — never commit tokens.

## Common tasks
| Task | Command |
|---|---|
| See if live drifted from source of truth | `scripts/fetch-blueprint.sh` then `git diff blueprints/` |
| Restore the scenario after UI corruption | `scripts/deploy-blueprint.sh` |
| Check a lead landed correctly | `scripts/verify-zoho.sh someone@example.com` |
| Read the real error of a failed run | Make: `incomplete-executions_list {scenarioId:9254191}` → `..._get {id}` |

## Related (not in this repo)
- Provisioner scenario `9254449` (creates missing Zoho text fields from the field registry; run manually).
- Data stores: `form_config 163354`, `field_registry 163355`, `submission_log 163356`, `provision_log 163373`.
