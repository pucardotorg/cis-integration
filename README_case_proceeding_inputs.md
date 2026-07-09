# Case proceeding typed inputs

Case proceeding now supports separate operator-facing input files by proceeding type. These are normalized into the flat runtime file consumed by the CIS bridge.

`court_no` now lives in `Data/config.json` as `COURT_NO`. The bridge first selects that configured court inside the same CIS login session, then immediately submits the proceeding for the CNR. Set `SKIP_COURT_SELECTION=true` to skip selection and emit a skip log.

- Typed catalogue: `Data/case-proceeding-types.json`
- Next-hearing input: `Data/case-proceeding-next-hearing-input.json`
- Disposal input: `Data/case-proceeding-disposal-input.json`
- Runtime bridge input: `Data/case-proceeding-input.json`

## Prepare next hearing

```bash
bash RUN_NORMALIZE_CASE_PROCEEDING.sh next_hearing
bash RUN_STAGE.sh case_proceeding
```

## Prepare non-bailable warrant / other non-appearance next hearing

Prefetch selects `COURT_NO` first, then preserves the fetched CIS purpose (for example `101 = NON BAILABLE WARRANT OF ACCUSED`) and saves dependent criminal proceeding panels: party presence options, appearance/process rows, 313 status rows, purpose options, and previous delay reasons. Review/edit the prefetched draft before submitting.

Simplified prefetch input is accepted in `Data/prefetch-input.json`:

```json
[
  { "id": "trial10", "cnr": "HRPK030049362021", "stages": "proceeding" }
]
```

Typed aliases `nbw`, `warrant`, `non-bailable-warrant`, and `non_bailable_warrant` normalize to a pending next-hearing record with `purpose_code=101`.

```json
{
  "type": "nbw",
  "external_id": "PROC-NBW-001",
  "cis_cnr": "HRPK030049362021",
  "proceeding_date": "07-07-2026",
  "next_hearing_date": "30-07-2026",
  "business_remarks": "hello",
  "counsel_present": ["MP", "MPA", "ER~1"]
}
```

```bash
bash RUN_NORMALIZE_CASE_PROCEEDING.sh Data/my-nbw-input.json
bash RUN_STAGE.sh case_proceeding
```

## Prepare disposal

```bash
bash RUN_NORMALIZE_CASE_PROCEEDING.sh disposal
bash RUN_STAGE.sh case_proceeding
```

## One-shot typed source

```bash
CASE_PROCEEDING_SOURCE_JSON=Data/case-proceeding-disposal-input.json bash RUN_STAGE.sh case_proceeding
```

Disposal is HAR-backed from `walkthro-23062026/case-proceeding_disposal.har` and emits `fdispose=on`, `fdormant=D`, `fdt_decision`, `radio_disp_type`, `fdisp_type`, and `checkval=true`.

Example typed next-hearing record:

```json
{
  "type": "next_hearing",
  "external_id": "trial-next-hearing-1",
  "cis_cnr": "HRPK020007192026",
  "proceeding_date": "03-07-2026",
  "purpose_code": "6",
  "next_hearing_date": "04-07-2026",
  "business_remarks": "paste it on the wall",
  "counsel_present": ["MP"]
}
```
