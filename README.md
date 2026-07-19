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
