# Cheque-only CIS Bridge Template

Files:

```text
Automation_Script/cheque_cis_bridge_template.sh
Automation_Script/cheque_bridge_payload_template.json
Automation_Script/verify_cheque_cis_bridge.sh   # droplet verification + cleanup
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

```bash
export CIS_BASE_URL="http://<cis-host>/swecourtis"
export COURT_CODE="HRPK02"
export CIS_USER="<cis-user>"
export CIS_PASSWORD="<cis-password>"

export MODERN_PULL_URL="https://your-app.example.com/api/cis/pending-cheque-filings"
export MODERN_CALLBACK_URL="https://your-app.example.com/api/cis/filing-result"
export MODERN_API_KEY="<shared-secret-or-token>"

bash Automation_Script/cheque_cis_bridge_template.sh
```

## Pull API response expected from your modern app

Return a JSON array. Example in:

```text
Automation_Script/cheque_bridge_payload_template.json
```

Minimum fields:

```json
[
  {
    "external_filing_id": "APP-123",
    "complainant_name": "ABC TRADERS",
    "accused_name": "RAJ KUMAR",
    "cheque_amount": "100000",
    "cause_of_action": "Cheque dishonoured due to insufficient funds.",
    "relief": "Complaint under Section 138 of Negotiable Instruments Act."
  }
]
```

Recommended fields include local-language names/addresses, mobile numbers, cheque number/date, dishonour date.

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

Run `Automation_Script/verify_cheque_cis_bridge.sh` on the droplet to:

1. Log in to CIS.
2. Submit one test NACT cheque-bounce filing.
3. Capture the generated Filing No. / CNR.
4. Delete the test case from `civil_t` and `ecivil_t`.
5. Log out of CIS.

Edit the hardcoded test payload inside the script before running.

## Notes

- This template uses curl, not direct SQL, for case creation.
- That is preferred because old CIS itself generates the Filing No. and CNR and updates its internal counters/tables.
- Keep SQL only for one-time setup or diagnostics, not for case creation.
- Test against a training/staging CIS first.
