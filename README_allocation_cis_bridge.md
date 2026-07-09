# Case-Allocation CIS Bridge Template

Files:

```text
uploader/V3/RUN_STAGE.sh allocation                  # standalone stage launcher
uploader/V3/source/allocation_cis_bridge_template.sh   # the worker
uploader/V3/Data/allocation-input.json                 # sample/editable input
uploader/V3/source/verify_allocation_cis_bridge.sh     # bulk read-only verifier (preflight/postcheck)
```

## What this is

Allocates an already-filed case (identified by CNR) to a target court in old CIS via the
**Bulk Allocation** screen (`registration/bulk_allocation.php`, linkid 93).

For each record it performs the exact UI sequence (radiotype 5 = by CNR):

1. `GET registration/bulk_allocation.php?linkid=93&mode=0` — load page / base form fields.
2. `POST bulk_allocationajax.php` `x=showdetails&cino=<CNR>` — validate the case is pending
   and fetch `casetypevalue`, `pet_name`, `res_name`, `case_no`.
3. `POST bulk_allocationajax.php` `x=fetchcourttable` — list available courts for the casetype;
   **`target_court_no` must be present in this list** or the record fails.
4. `POST bulk_allocationajax.php` `x=behaviourfetch` — behaviour flag.
5. `POST bulk_allocationajax.php` `...&formaction=8` — **the allocation** (case → `court_no`).
6. `POST bulk_allocationajax.php` `x=showdetails` again — **post-check**. If `numrow==0` the
   case has left the pending pool ⇒ allocation succeeded. This is the primary success signal
   (the `formaction=8` response shape varies; raw response is always saved for audit).

Login is hardened: if CIS returns `UserLogged` (user already logged in), the bridge calls
`index_unlock.php` / `loginajax1.php` `x=checkunlock_fromindex` to unlock, then retries.

## Configuration

```bash
export CIS_BASE_URL="http://<cis-host>/swecourtis"
export COURT_CODE="HRPK02"
export CIS_USER="<cis-user>"
export CIS_PASSWORD="<cis-password>"
export UNLOCK_PASSWORD="<unlock-password>"   # optional, defaults to CIS_PASSWORD
export INPUT_JSON="allocation-input.json"
export OUTPUT_JSON="cis-allocation-results.json"
bash allocation_cis_bridge_template.sh
```

## Input record

```json
{
  "external_id": "APP-123",
  "cis_cnr": "HRPK030093392026",
  "fmm_case_type": "55",          // optional, default 55 (NACT)
  "target_court_no": "41",        // REQUIRED — must be a court returned by fetchcourttable
  "allocation_dt": "23-06-2026"   // optional, default today (dd-mm-YYYY)
}
```

`target_court_no` is mandatory. `next_date` / `purpose` are left empty (optional in CIS).

## Output record

```json
{
  "external_id": "APP-123",
  "cis_cnr": "HRPK030093392026",
  "status": "success",
  "allocated_court_no": "41",
  "postcheck_numrow": "0",
  "submit_response": {},
  "postcheck_response": {}
}
```

On failure `status` is `failed` with an `error` message; the raw `submit_response` is saved.

## Important CIS constants

```text
Bulk allocation page: /swecourtis/registration/bulk_allocation.php?linkid=93&mode=0
Allocation AJAX:      /swecourtis/registration/bulk_allocationajax.php
radiotype:            5   (by CNR / registration number)
formaction:           8   (allocate, for radiotype 4/5)
                       5 = court-wise, 6 = case-wise, 7 = police-station-wise
Unlock user:          /swecourtis/index_unlock.php  -> POST loginajax1.php x=checkunlock_fromindex
```

## Verifier

`verify_allocation_cis_bridge.sh` is **read-only** (no writes, no rollback — safe on the whole batch):

- `--preflight <input.json>` — per CNR runs `showdetails` + `fetchcourttable`; reports
  found / casetype / pet-res / already-allocated / `target_court_no` not in available courts.
  Any `error` rows gate the run when used via the pipeline (`ABORT_ON_PREFLIGHT_ERROR=yes`).
- `--postcheck <output.json>` — per CNR re-runs `showdetails`; `numrow==0` ⇒ allocated.

Writes `verification-report.json` + prints a summary.

## Notes

- The `formaction=8` response was not captured in the reference HAR (response bodies were
  not recorded). The bridge therefore treats **post-check `showdetails` numrow==0** as the
  success signal and always saves `submit_response` for audit. On the first live run, inspect
  `submit_response` to confirm and, if a cleaner success flag exists, it can be added to the
  success check in `allocate_case_to_cis`.
- Run via `RUN_PIPELINE.sh` for the create→allocate flow; allocation input is built from the
  filing output by `transform_filing_to_allocation.py` (Option A: `target_court_no` is carried
  through the filing input/output).
