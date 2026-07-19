# Roadmap — dristi-v2 integration & auto-fire pipeline

> Status: **planning**. This doc captures the three pending workstreams that move
> the V3 uploader from a standalone, hand-driven tool into an automated,
> `dristi-v2`-driven CIS integration. It is the companion to
> `README_pipeline.md` (how the pipeline works *today*).

---

## Context — where we are today

The uploader (`uploader/V3`, repo `github.com/pucardotorg/cis-integration`) is a
**standalone** app. An operator:

1. Hand-creates the input JSON for each stage under `Data/` (e.g.
   `cis-daily-filings-2026-06-26.json`, `allocation-input.json`, …).
2. Edits `Data/config.json` (CIS connection + active court).
3. Runs `bash RUN_PIPELINE.sh` (all stages) or `bash RUN_STAGE.sh <stage>` (one
   stage). Each stage: optional transform → preflight → bridge → postcheck.

The dristi-v2 app (`D:\DeltaXY-AI\dristi-v2`, repo `github.com/pucardotorg/dristi-v2`)
already owns the **e-filing** use case end-to-end:

- `lib/cis-export.ts` — `exportReadyCasesForCIS(courtId)` atomically transitions
  cases `READY_FOR_CIS → EXPORTED_FOR_CIS` and emits a `CISBridgePayload[]`.
- `app/api/cis/daily-export/route.ts` — `GET` (auth-gated) returns that payload.
- `lib/cis-import.ts` — `importCISResults()` transitions
  `EXPORTED_FOR_CIS → FILED_IN_CIS` (stores `cnr_number`) or `CIS_FAILED`.
- `app/api/cis/import-results/route.ts` — `POST` accepts CIS results back.
- `Automation_Script/cheque_cis_bridge_template.sh` — polls `daily-export`,
  logs into CIS, submits NACT/138 filings, posts results to `import-results`.
- Case lifecycle in `db/schema/case.ts`:
  `DRAFT → READY_FOR_CIS → EXPORTED_FOR_CIS → FILED_IN_CIS | CIS_FAILED`.

So today dristi-v2 only covers **stage 1 (filing)**, and only for
`case_type = "NI_ACT_138"` (cheque bounce). The uploader covers the full chain
(filing → allocation → select_court → case_objection → registration →
case_proceeding → bulk_order_upload → process_prefetch → process_generation →
process_upload → publish_process) but its inputs are hand-built and each step is
fired manually.

---

## The three pending workstreams

### 1. Inputs driven from dristi-v2 (not hand-created)

**Goal:** `Data/*.json` stage inputs are no longer authored by hand. They are
produced by dristi-v2 export endpoints and dropped into the uploader's `Data/`
folder (or fetched on demand) so the uploader stays a pure CIS-execution engine.

**Known gaps:**

- **Format mismatch on filing.** dristi-v2's `CISBridgePayload` (see
  `lib/cis-export.ts`) does **not** carry the fields the V3 filing bridge
  consumes from `Data/cis-daily-filings-*.json`:
  `target_court_no`, `fmm_case_type`, `allocation_dt`, `court_fee`,
  `court_fee_paid`, `advocate_code`, local-language name/address fields, etc.
  - `target_court_no` / `allocation_dt` are the "Option A" single-source-of-truth
    fields documented in `README_pipeline.md` — they must originate in dristi-v2
    (court assignment decision), not be added in the uploader.
  - Fix: extend `cis-export.ts` (and the `daily-export` response) to include
    `target_court_no`, `fmm_case_type`, `allocation_dt`, fee + advocate-code
    fields, and local-language strings; or add a dedicated
    `/api/cis/pipeline-input/<stage>` endpoint per stage.
- **No export for downstream stages.** Allocation, case_objection, registration,
  case_proceeding, bulk_order_upload, process_* all have inputs in `Data/` that
  are today built by transforms (`transform_*_to_*.py`) chained off the **filing**
  output. dristi-v2 has no concept of these stages yet.

**Tasks:**

- [ ] Define a shared **pipeline input contract** (`CISPipelineStageInput`) used
  by both repos — versioned, with a `schema_version` field.
- [ ] Extend `cis-export.ts` to emit the full filing-stage input (with
  `target_court_no`, `allocation_dt`, `fmm_case_type`, fees, advocate code, local
  language). Keep the atomic `READY_FOR_CIS → EXPORTED_FOR_CIS` transition.
- [ ] Add dristi-v2 endpoints to serve per-stage inputs (or a single
  `/api/cis/pipeline-input` that returns the manifest of ready stages):
  - `/api/cis/inputs/allocation`
  - `/api/cis/inputs/registration`
  - `/api/cis/inputs/case-proceeding`
  - `/api/cis/inputs/bulk-order-upload`
  - `/api/cis/inputs/process-generation`
- [ ] Add a dristi-v2 callback for **every** stage result, not just filing.
  Today only `/api/cis/import-results` exists (filing only). Generalize to
  `/api/cis/import-results/<stage>` (or a single endpoint keyed by `stage`).
- [ ] Extend the case lifecycle in `db/schema/case.ts` /
  `lib/cis-import.ts` to model the full chain
  (`FILED_IN_CIS → ALLOCATED → REGISTERED → …`) instead of stopping at
  `FILED_IN_CIS`.
- [ ] Replace the uploader's hand-authored `Data/cis-daily-filings-*.json` and
  the transform-generated `Data/allocation-input.json` etc. with a fetch step
  (the uploader pulls from dristi-v2, or dristi-v2 pushes into the watched
  `Data/inbox/` folder — see workstream 3).

### 2. Expand efiling beyond cheque/NACT

**Goal:** dristi-v2 currently only exports `case_type = "NI_ACT_138"`. The
uploader already supports the full post-filing chain generically. dristi-v2 must
drive **other use cases** (case types and stage mixes), reusing the uploader's
generic stage machinery.

**Scope to expand:**

- Non-cheque criminal case types and civil case types (today the uploader filing
  bridge hardcodes `ffiling_no_type = 55 (NACT)` — see `README_cheque_cis_bridge.md`).
- Post-filing flows that dristi-v2 does not model yet:
  - Allocation (`bulk_allocation`, `formaction=8`)
  - Court mapping / select_court
  - Scrutiny / case_objection
  - Registration
  - Case proceedings (next-hearing, disposal, NBW — see
    `README_case_proceeding_inputs.md`)
  - Bulk order/judgment upload
  - Process generation + upload + publish (summons/notices)

**Tasks:**

- [ ] Generalize the filing bridge: make `fmm_case_type` / `ftype_of_filing` /
  `civ_cri_cav` / `ffiling_no_type` data-driven from the input record rather
  than hardcoded NACT/138. Document the verified CIS constant per case type.
- [ ] Model additional `case_type` values + statutes in dristi-v2
  (`db/schema/case.ts`, `caseStatutesSections`) and the filing form/UI.
- [ ] Add dristi-v2 domain logic (services + DB transitions) for allocation,
  scrutiny, registration, proceedings, order upload, process — each mirrors the
  existing `READY_FOR_CIS → EXPORTED_FOR_CIS → <done>` pattern but for its stage.
- [ ] Per use case, record a reference HAR under
  `uploader/V3/har`/`walkthro-*` (as was done for cheque + disposal) so the
  bridge request sequence is verifiable.
- [ ] Update `README_cheque_cis_bridge.md` → rename/generalize to
  `README_filing_cis_bridge.md` covering all supported case types, with NACT/138
  as one example.

### 3. Auto-fire pipeline (inputs in folder → stages fire automatically)

**Goal:** Today each step is fired by a human (`RUN_STAGE.sh <stage>` or one
`RUN_PIPELINE.sh`). Replace with a **watcher**: when an input file lands in the
input folder, the matching stage(s) fire automatically, respecting the
transform chain.

**Current behavior to preserve:**

- `RUN_PIPELINE.sh` already chains stages via `transform_from` / `transform_script`
  in `Data/pipeline.json` and aborts on preflight error
  (`ABORT_ON_PREFLIGHT_ERROR=yes`). It writes per-run outputs to
  `output/DDMMYYYY/<run-id>-…` and a `pipeline-summary.json`.
- `RUN_STAGE.sh <stage>` runs one stage in isolation.
- `fetch_stage_inputs.sh` is a read-only prefetch that builds stage inputs from
  CIS (registration + case-proceeding) and drops them into `Data/*.prefetched.json`.

**Proposed new flow:**

```
dristi-v2  ──push──▶  Data/inbox/<stage>-input.json   (or uploader pulls via fetch)
                         │
                  ┌──────▼──────┐
                  │  watcher    │  (new: RUN_WATCHER.sh)
                  │  (inotify)  │  detects new/changed file → enqueues stage
                  └──────┬──────┘
                         │
            resolve stage(s) from pipeline.json (input_file → stage)
                         │
            ┌────────────▼────────────┐
            │ stage runner (per stage) │  reuses existing bridge/transform logic
            │  transform → preflight   │  writes output/DDMMYYYY/<run-id>-…
            │  → bridge → postcheck    │
            └────────────┬────────────┘
                         │
            downstream stages whose transform_from = this stage
            are auto-enqueued when the upstream output lands
                         │
                  results posted back to dristi-v2
                  (/api/cis/import-results/<stage>)
```

**Design decisions to make:**

- **Trigger mechanism.** `inotifywait` (Linux) watching `Data/inbox/` is the
  natural fit for the court-side portable package
  (`README_LINUX_PORTABLE.md`). On Windows dev, a polling fallback (every N s)
  in Python. Keep the watcher dependency-free (Python stdlib + `inotifywait`
  when available).
- **Inbox vs overwrite.** Inputs land in `Data/inbox/<stage>-input.json`; the
  watcher atomically moves them into the stage's declared `input_file` path
  (from `pipeline.json`) before firing, so half-written files never trigger a
  run. Use `mv` after a write-temp-then-rename, or watch `CLOSE_WRITE`/`MOVED_TO`.
- **Stage resolution.** A new `source/resolve_stages.py` maps
  `input_file → [stage names]` from `pipeline.json`. One input file may map to
  multiple stages (e.g. filing output feeds allocation, case_objection).
- **Chaining.** After a stage's output is written, the watcher re-resolves any
  stage whose `transform_from == <this stage>` and auto-fires the transform +
  that stage. This is the same logic `RUN_PIPELINE.sh` does linearly; the
  watcher makes it event-driven.
- **Concurrency / locking.** One CIS login session at a time per court
  (bridges already self-heal `UserLogged` via `index_unlock.php`). The watcher
  must serialize stages that hit the same `COURT_NO` and use a per-stage lock
  file under `output/.locks/`.
- **Idempotency.** Each input record must carry a stable `external_filing_id`
  / `external_id` (already required by every bridge). The watcher tracks
  processed `(stage, external_id)` in `output/.processed.jsonl` to avoid
  re-firing on duplicate file notifications.
- **Failure handling.** Mirror dristi-v2's "case is never lost" principle: a
  failed stage writes a failure record, posts it back to dristi-v2, and the
  case sits in its pre-stage state for retry. Preflight errors keep aborting
  the stage (no partial CIS writes).
- **Manual override.** Keep `RUN_STAGE.sh` and `RUN_PIPELINE.sh` working as
  today for ops/debugging. The watcher is an additive layer.

**Tasks:**

- [ ] Define `Data/inbox/` convention + atomic handoff (temp-write → rename).
- [ ] `source/resolve_stages.py` — input_file → stages, and
  transform_from → downstream stages, from `pipeline.json`.
- [ ] `RUN_WATCHER.sh` + `source/watcher.py` — inotify (Linux) / poll
  (Windows) loop; per-stage lock + processed ledger; calls into the existing
  bridge/transform logic (do not duplicate it).
- [ ] Reuse `RUN_STAGE.sh`'s bridge invocation (env: `INPUT_JSON`, `OUTPUT_JSON`,
  `UPLOADER_APP_DIR`, CIS config from `load_config.sh`) so the watcher does not
  reimplement stage execution.
- [ ] Back-pressure / pause: a `Data/pause` sentinel file that stops the watcher
  from firing new runs (ops escape hatch during CIS maintenance).
- [ ] Results callback: after each stage, post its output to dristi-v2's
  generalized `/api/cis/import-results/<stage>` (workstream 1).
- [ ] Observability: append to `output/DDMMYYYY/<run-id>-watcher.log` and the
  existing `pipeline-summary.json` / `run-manifest.json` so runs are auditable
  whether fired by a human or the watcher.
- [ ] Tests under `tests/` for: file-landed → stage-fired; transform chaining;
  duplicate suppression; lock contention; pause sentinel.

---

## Cross-repo contract (single source of truth)

Both repos must agree on. Version it (`schema_version`):

```jsonc
// dristi-v2 → uploader  (stage input, e.g. filing)
{
  "schema_version": 1,
  "stage": "filing",
  "court_id": "...",
  "court_code": "HRPK02",
  "records": [
    {
      "external_filing_id": "<dristi-v2 case.id>",
      "app_filing_number": "FL-...",
      "case_type": "NI_ACT_138",            // workstream 2: more types
      "fmm_case_type": "55",
      "target_court_no": "48",              // originates in dristi-v2
      "allocation_dt": "26-06-2026",
      "court_fee": "10",
      "advocate_code": "298",
      "complainant_name": "...",
      "complainant_local_name": "...",
      /* …all CISBridgePayload fields + V3-only fields… */
    }
  ]
}
```

```jsonc
// uploader → dristi-v2  (stage result)
{
  "schema_version": 1,
  "stage": "filing",                       // workstream 1: generalize beyond filing
  "results": [
    {
      "external_filing_id": "<dristi-v2 case.id>",
      "status": "success",                 // | "failed"
      "cis_cnr": "HRPK020007022026",
      "cis_filing_no": "NACT/23/2026",
      "registered_case_number": "NACT/4/2026",   // present for registration stage
      "error": "",                          // present on failure
      "raw_cis_response": {}
    }
  ]
}
```

---

## Sequencing

1. **Workstream 1 (contract + endpoints)** first — without a defined, versioned
   input contract, the watcher (3) and the case-type expansion (2) have nothing
   stable to build on.
2. **Workstream 3 (auto-fire watcher)** next — it makes the uploader reusable
   as-is against the new contract, with dristi-v2 simply dropping files.
3. **Workstream 2 (more use cases / case types)** last — additive: each new
   case type or stage is then just a new `pipeline.json` entry + a dristi-v2
   domain transition, picked up automatically by the watcher.

---

## What does NOT change

- The bridge scripts (`source/*_cis_bridge.sh`) and transforms
  (`source/transform_*.py`) stay as the CIS-execution core. They are
  input-format-driven and case-type-agnostic where possible.
- `Data/config.json` remains the single source of truth for CIS connection.
- `Data/pipeline.json` remains the stage manifest; the watcher reads it.
- Per-run outputs stay under `output/DDMMYYYY/<run-id>-…` with the same
  summary + run-manifest format.
- The data editor (`README_data_editor.md`) stays; it gains a "watcher
  status" panel.
