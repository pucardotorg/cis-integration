# Uploader V3 — CIS integration (cis-integration repo)

A standalone, court-side pipeline that drives the legacy **CIS** (Court
Information System) AJAX interface through an ordered list of "use case" stages:
create a case, allocate it, scrutinize it, register it, record proceedings,
upload orders, generate and publish process/summons. One command per stage or
one command for the whole chain.

- **Repo:** `github.com/pucardotorg/cis-integration` → `uploader/V3/`
- **Sibling app:** `github.com/pucardotorg/dristi-v2` — owns e-filing today; the
  uploader is the generic CIS-execution engine.

## Docs map

| Doc | What it covers |
|---|---|
| [`README_pipeline.md`](./README_pipeline.md) | The orchestrator: `RUN_PIPELINE.sh`, the `pipeline.json` manifest, stage chaining via transforms, preflight/postcheck, summary + run manifest. Read this first. |
| [`ROADMAP_dristi_v2_integration.md`](./ROADMAP_dristi_v2_integration.md) | **Pending work:** (1) source inputs from dristi-v2 instead of hand-authoring them, (2) expand beyond cheque/NACT to other use cases, (3) auto-fire stages from a watcher when inputs land in the input folder. |
| [`README_cheque_cis_bridge.md`](./README_cheque_cis_bridge.md) | Stage 1 (filing) bridge for NACT/138 cheque-bounce cases. Config, pull/callback API contract, CIS constants. |
| [`README_allocation_cis_bridge.md`](./README_allocation_cis_bridge.md) | Stage 2 (allocation) bridge: `bulk_allocation` (`formaction=8`), `target_court_no` requirement, read-only verifier. |
| [`README_case_proceeding_inputs.md`](./README_case_proceeding_inputs.md) | Stage 6 (case proceeding): typed next-hearing / disposal / NBW inputs, normalization, court selection. |
| [`README_submission_inputs_from_har.md`](./README_submission_inputs_from_har.md) | HAR-backed reference request sequence for allocation, scrutiny, registration, and proceeding disposal. |
| [`README_data_editor.md`](./README_data_editor.md) | Browser-based editor for `Data/*.json` (inputs, manifest, `config.json`) + run/output panels. |
| [`README_LINUX_PORTABLE.md`](./README_LINUX_PORTABLE.md) | Building the portable Linux package for the court server. |

## Layout

```
uploader/V3/
├── RUN_PIPELINE.sh          # run all enabled stages (chain)
├── RUN_STAGE.sh             # run one stage
├── RUN_DATA_EDITOR.sh       # web editor for Data/*.json
├── RUN_NORMALIZE_CASE_PROCEEDING.sh
├── RUN_ADVOCATE_LOOKUP.sh
├── fetch_stage_inputs.sh    # read-only prefetch from CIS
├── Data/                     # inputs + manifest + config (hand-authored today)
│   ├── pipeline.json         # stage manifest
│   └── config.json           # CIS connection (single source of truth)
├── source/                   # bridge scripts + transforms + fetchers
├── output/                   # runtime results: output/DDMMYYYY/<run-id>-…
├── tools/                    # data editor
├── packaging/                # portable build
└── tests/
```

## Run

```bash
cd uploader/V3
bash RUN_PIPELINE.sh --validate    # check inputs present (no CIS calls)
bash RUN_PIPELINE.sh               # run the full chain
bash RUN_STAGE.sh --list           # list stages from pipeline.json
bash RUN_STAGE.sh allocation       # run one stage
```

## Current state vs target

The pipeline works end-to-end today but is **standalone and hand-driven**. The
target — sourcing inputs from dristi-v2 and auto-firing stages — is documented in
[`ROADMAP_dristi_v2_integration.md`](./ROADMAP_dristi_v2_integration.md).

## What this is not

These are the known limitations of V3 today. Most are flagged as pending work
in the roadmap.

1. **Not a fully functional CIS integration.** It is a stage-by-stage
   execution engine that drives a subset of the CIS AJAX flow for specific use
   cases (NACT/138 cheque-bounce, post-filing chain). It is not a complete,
   production-grade CIS integration.
2. **Inputs were built manually.** Most `Data/*.json` inputs were hand-authored.
   A few stages have a read-only prefetch (`fetch_stage_inputs.sh`, the
   `process_prefetch` stage, `case_identity`) that pulls data from CIS, but the
   majority of inputs are created by hand or by transforms chained off the
   filing output — not sourced from the modern system.
3. **Integration with the new system is not fully available.** The dristi-v2
   integration — sourcing inputs from the modern app's export endpoints and
   posting results back per stage — is **planning only**, not built. Today only
   stage 1 (filing) has a partial bridge on the dristi-v2 side; the full chain
   is not wired up. See `ROADMAP_dristi_v2_integration.md`.
4. **Not all scenarios are covered.** The pipeline is built around NACT/138
   cheque-bounce cases. Other case types, statutes, and stage mixes are not
   yet wired up. The filing bridge hardcodes `ffiling_no_type = 55 (NACT)`.
5. **Court number is assumed static.** `COURT_NO` lives in `Data/config.json`
   and is treated as a single fixed court (one court per deployment). It also
   appears in some input JSONs (`case-proceeding-input.json`,
   `select-court-input.json`, `process-status-input.json`), but the bridges
   read it from env/config first and fall back to the record value — so the
   per-record value is effectively unused. For a multi-court deployment the
   new filing system should pass `court_no` per record and the bridges should
   rely on the record, not the config.
6. **`filing_no` is not mandatory for order uploads.** `bulk_order_upload`
   requires `cis_cnr` + the registered `case_no` (digits only); it does not
   require `cis_filing_no`. This is intentional for cases e-filed on eCourts
   (a different system): the CIS `filing_no` may not exist, but the order can
   still be uploaded against the registered case.
