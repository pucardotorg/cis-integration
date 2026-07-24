# Submission input JSON from `walkthro-23062026/168.144.70.80.har`

> The reference HAR is archived at the repo root as `har files.7z` (the live
> `walkthro-23062026/` directory is no longer checked out). Extract it with
> `7z x "har files.7z"` if you need to re-walk the request sequence.

This HAR contains a complete post-filing path for one NACT/138 case:

```text
CNR / filing CINO: HRPK020007022026
Filing no:        205500000232026 / NACT/23/2026
Case type:        55 (NACT)
Criminal flag:    3
Petitioner:       dummy1
Respondent:       dummy2
Dates:            26-06-2026 for allocation/scrutiny/registration/listing
Purpose:          6
Allocated court:  48
Registered case:  NACT/4/2026 (case_number 205500000042026)
```

## Files prepared

```text
Data/allocation-input.json
Data/case-objection-input.json
Data/registration-input.json
```

These are minimal bridge inputs. The bridge scripts fetch party/act/address details from CIS with `showdetails` and merge the fetched values into the submitted form.

## HAR-backed request sequence

### 1) Allocation

HAR entry 0 posts directly to:

```text
POST /swecourtis/registration/bulk_allocationajax.php
```

Key fields:

```json
{
  "cis_cnr": "HRPK020007022026",
  "fmm_case_type": "55",
  "target_court_no": "48",
  "allocation_dt": "26-06-2026",
  "next_date": "26-06-2026",
  "purpose_code": "6"
}
```

CIS response in HAR:

```json
{"count1":0,"msg2":"Case allocated to the Court-48"}
```

The V3 allocation bridge now also carries `next_date` and `purpose_code` into the submit payload, matching this HAR.

### 2) Case objection / scrutiny

HAR entries 127, 130, 131:

```text
POST case_objectionajax.php x=showdetails&ffiling_no=HRPK020007022026&opt=undefined
POST case_objectionajax.php formaction=1&fobj_sel=N&fobj_flag=Y&scrutiny_date=26-06-2026
POST case_objectionajax.php x=caseObjectionComponent
```

Prepared input:

```json
{
  "cis_cnr": "HRPK020007022026",
  "fmm_case_type": "55",
  "fci_cri": "3",
  "fobj_sel": "N",
  "fobj_flag": "Y",
  "scrutiny_date": "26-06-2026",
  "fobjreturn_dt": "",
  "fobj_redate": "",
  "fobjreceipt_dt": "",
  "fobjection": "",
  "flobjection": "",
  "fobjdescription": ""
}
```

CIS response in HAR:

```json
{"count1":0,"msg2":"Modification successful","success":"Y"}
```

### 3) Registration

HAR entries 179, 186, 246 are the important final path:

```text
POST registrationajax.php x=appellateCourt
POST registrationajax.php x=showdetails&filingno=HRPK020007022026&mode_of_filing=2
POST registrationajax.php flag=Register&ftab_status=P~R~E~A~F&fpurpose_code=6...
```

Prepared input:

```json
{
  "cis_cnr": "HRPK020007022026",
  "fmm_case_type": "55",
  "fci_cri": "3",
  "registration_dt": "26-06-2026",
  "listing_dt": "26-06-2026",
  "purpose_code": "6",
  "registration_year": "2026",
  "mode_of_filing": "2",
  "role": "1",
  "ftab_status": "P~R~E~A~F",
  "fdispactcode": ["Negotiable Instruments Act"],
  "fhiddactcode": ["18810260099001 "],
  "factcode": ["732"],
  "factsection_code": ["138"]
}
```

CIS response in HAR:

```json
{"count1":0,"msg2":"Addition successful<br/>Case No.:-NACT/4/2026","success":"Yes","case_number":"205500000042026"}
```

## Individual stage run commands

From the version folder:

```bash
cd uploader/V3
bash RUN_STAGE.sh allocation
bash RUN_STAGE.sh case_objection
bash RUN_STAGE.sh registration
```

Each stage reads input/output/bridge paths from `Data/pipeline.json` and writes to
`output/DDMMYYYY/<run-id>-...results.json`.
