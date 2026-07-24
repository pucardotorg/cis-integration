# Cheque-only CIS Bridge Template

Files:

```text
source/cheque_cis_bridge_template.sh         # the worker (curl + openssl + python)
Data/cis-daily-filings-2026-06-26.json        # sample file-mode input (real record shape)
```

## What this is

A template for a one-command court-side bridge script.

The court runs one script. The script:

1. Pulls pending cheque filings from your modern application API.
2. Logs into old CIS using curl.
3. Submits the cheque case as `NACT - 138 NIA ACT` through old CIS Filing Counter AJAX.
   - Verified values for this CIS:
     - `ftype_of_filing = 3` (Criminal)
     - `civ_cri_cav = 3` (Criminal)
     - `ffiling_no_type = 55` (NACT)
4. Receives CIS Filing No. and CNR No.
5. Pushes the result back to your modern app callback API.
6. Logs out of CIS.

Court staff does not need to open CIS UI or copy output.

## Configuration

The bridge runs in two modes. **File mode** is the pipeline default:
`RUN_PIPELINE.sh` / `RUN_STAGE.sh` load `Data/config.json` via
`source/load_config.sh` (exports `CIS_BASE_URL`, `COURT_CODE`, `CIS_USER`,
`CIS_PASSWORD`, `UNLOCK_PASSWORD`, `LOGIN_DATE`, `LANG_ID`, `CLOUD_FLAG`,
`COURT_NO`, …) and set `INPUT_JSON` / `OUTPUT_JSON` from `Data/pipeline.json`.

```bash
cd uploader/V3
bash RUN_STAGE.sh filing                       # file mode (pipeline default)
# or standalone:
export CIS_BASE_URL COURT_CODE CIS_USER CIS_PASSWORD   # or: source source/load_config.sh .
export INPUT_JSON="Data/cis-daily-filings-2026-06-26.json"
export OUTPUT_JSON="output/cis-results.json"
bash source/cheque_cis_bridge_template.sh
```

**API mode** (pull from / push to a modern app) is the alternative — set
`MODERN_PULL_URL` + `MODERN_CALLBACK_URL` instead of `INPUT_JSON` / `OUTPUT_JSON`:

```bash
export CIS_BASE_URL="http://<cis-host>/swecourtis"
export COURT_CODE="HRPK02"
export CIS_USER="<cis-user>"
export CIS_PASSWORD="<cis-password>"
export MODERN_PULL_URL="https://your-app.example.com/api/cis/daily-export"
export MODERN_CALLBACK_URL="https://your-app.example.com/api/cis/import-results"
export MODERN_API_KEY="<shared-secret-or-token>"
bash source/cheque_cis_bridge_template.sh
```

## Pull API response expected from your modern app (API mode)

Return a JSON array. A real file-mode sample lives at
`Data/cis-daily-filings-2026-06-26.json` (same shape works for API mode — the
bridge reads whichever `INPUT_JSON` or `MODERN_PULL_URL` provides).

Minimum fields (record shape used by the bridge):

```json
[
  {
    "external_filing_id": "APP-123",
    "app_filing_number": "FL-123",
    "court_fee": "10",
    "court_fee_paid": "10",
    "complainant_name": "ABC TRADERS",
    "complainant_address": "Address 1",
    "complainant_mobile": "9999999999",
    "complainant_age": "35",
    "accused_name": "RAJ KUMAR",
    "accused_address": "Address 2",
    "accused_mobile": "8888888888",
    "accused_age": "40",
    "advocate_name": "Advocate Name",
    "advocate_bar_number": "P/1234/2020",
    "advocate_code": "298",
    "cheque_amount": "100000",
    "cheque_number": "123456",
    "cheque_date": "01-06-2026",
    "dishonour_date": "05-06-2026",
    "cause_of_action_date": "05-06-2026",
    "cause_of_action": "Cheque dishonoured due to insufficient funds.",
    "relief": "Complaint under Section 138 of Negotiable Instruments Act."
  }
]
```

Recommended additions: local-language name/address fields, advocate email/mobile
(retained for upstream/audit; the CIS filing form has no advocate mobile/email field).

## Callback API payload sent to your modern app

On success:

```json
{
  "external_filing_id": "APP-123",
  "status": "success",
  "court_code": "HRPK02",
  "cis_case_type": "NACT",
  "cis_case_type_code": 55,
  "cis_filing_no": "NACT/7/2026",
  "cis_cnr": "HRPK020006872026",
  "raw_cis_response": {}
}
```

On failure:

```json
{
  "external_filing_id": "APP-123",
  "status": "failed",
  "error": "CIS submission failed; check bridge logs on court machine"
}
```

## Important CIS constants

```text
NACT case type code: 55
NACT full form: Negotiable Instruments Act
Used for: Section 138 cheque bounce cases
Filing endpoint: /swecourtis/filing/civil_filingajaxnew.php
```

## Verification

The filing stage has no read-only verifier (unlike allocation, which has
`source/verify_allocation_cis_bridge.sh` as preflight/postcheck). For a no-write
smoke check use the pipeline flags:

```bash
bash RUN_PIPELINE.sh --validate        # confirm filing input JSON present + well-formed
bash RUN_STAGE.sh filing --dry-run     # resolve paths + config, no CIS calls
```

To verify a live filing end-to-end, run the stage against a training/staging CIS
and inspect `output/DDMMYYYY/<run-id>-cis-results.json` for `cis_cnr` per record.

## Notes

- This template uses curl, not direct SQL, for case creation.
- That is preferred because old CIS itself generates the Filing No. and CNR and updates its internal counters/tables.
- Keep SQL only for one-time setup or diagnostics, not for case creation.
- Test against a training/staging CIS first.
