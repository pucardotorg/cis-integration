#!/usr/bin/env python3
"""
Transform filing-stage output -> case-objection input.

Default behaviour is "no objection / ready for registration" so the following
registration stage can proceed. If a filing result already carries objection fields
(fobj_sel, objection_text, etc.), they are passed through.

Emits:
  {
    "external_id": "...",
    "cis_cnr": "HRPK...",
    "fmm_case_type": "55",
    "fobj_sel": "N",
    "fobj_flag": "Y",
    "scrutiny_date": "dd-mm-YYYY"
  }

Usage:
  python3 transform_filing_to_case_objection.py <filing_output.json> <case_objection_input.json> [summary.json]
"""
import datetime
import json
import sys


def normalized_acts(record):
    default_act = {
        "act_display": "Negotiable Instruments Act-732",
        "hidden_act_code": "18810260099001",
        "act_code": "732",
        "section_code": "138,",
    }
    out = [default_act]
    seen = {(default_act["hidden_act_code"], default_act["act_code"], default_act["section_code"].rstrip(","))}
    for act in record.get("acts") or []:
        if not isinstance(act, dict):
            continue
        row = {
            "act_display": act.get("act_display") or act.get("act_name") or act.get("name") or "",
            "hidden_act_code": act.get("hidden_act_code") or act.get("hiddactcode") or act.get("national_code") or "",
            "act_code": act.get("act_code") or act.get("code") or act.get("actvalue") or "",
            "section_code": act.get("section_code") or act.get("section") or act.get("secvalue") or "",
        }
        key = (row["hidden_act_code"], row["act_code"], str(row["section_code"]).rstrip(","))
        if key not in seen:
            seen.add(key)
            out.append(row)
    return out


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: transform_filing_to_case_objection.py <filing_output.json> <case_objection_input.json> [summary.json]")
    src, dst = sys.argv[1], sys.argv[2]
    summary_path = sys.argv[3] if len(sys.argv) > 3 else None

    records = json.load(open(src, encoding="utf-8"))
    if not isinstance(records, list):
        sys.exit("filing output must be a JSON array")

    today = datetime.date.today().strftime("%d-%m-%Y")
    out = []
    dropped_failed = 0
    dropped_no_cnr = 0
    for r in records:
        if not isinstance(r, dict) or r.get("status") != "success":
            dropped_failed += 1
            continue
        cnr = r.get("cis_cnr")
        if not cnr:
            dropped_no_cnr += 1
            continue
        objection_text = r.get("objection_text") or r.get("fobjection") or ""
        fobj_sel = r.get("fobj_sel") or ("Y" if objection_text else "N")
        out.append({
            "external_id": r.get("external_filing_id") or r.get("external_id"),
            "cis_cnr": cnr,
            "cis_filing_no": r.get("cis_filing_no"),
            "fmm_case_type": str(r.get("fmm_case_type") or r.get("cis_case_type_code") or "55"),
            "fci_cri": str(r.get("fci_cri") or "3"),
            # Preserve complainant advocate values captured at filing; registration
            # showdetails does not reliably return these fields.
            "advocate_name": r.get("advocate_name"),
            "advocate_bar_number": r.get("advocate_bar_number"),
            "advocate_code": r.get("advocate_code"),
            "advocate_type": r.get("advocate_type"),
            "complainant_advocate_name": r.get("complainant_advocate_name") or r.get("advocate_name"),
            "complainant_advocate_barcode": r.get("complainant_advocate_barcode") or r.get("advocate_bar_number"),
            "complainant_advocate_code": r.get("complainant_advocate_code") or r.get("advocate_code"),
            "complainant_advocate_type": r.get("complainant_advocate_type") or r.get("advocate_type"),
            # Preserve organization and act metadata captured at filing; later stages
            # may need these because showdetails can omit org markers and extra acts.
            "complainant_party_type": r.get("complainant_party_type"),
            "complainant_org_id": r.get("complainant_org_id"),
            "complainant_extra_count": r.get("complainant_extra_count"),
            "accused_party_type": r.get("accused_party_type"),
            "accused_org_id": r.get("accused_org_id"),
            "accused_extra_count": r.get("accused_extra_count"),
            "acts": normalized_acts(r),
            "fobj_sel": str(fobj_sel),
            "fobj_flag": str(r.get("fobj_flag") or "Y"),
            # HAR 168.144.70.80 shows no-objection submit with scrutiny_date set, but
            # fobjreturn_dt left blank. Only use return-date defaults when an objection is raised.
            "scrutiny_date": r.get("scrutiny_date") or r.get("allocation_dt") or today,
            "fobjreturn_dt": r.get("fobjreturn_dt") or (r.get("scrutiny_date") or today if str(fobj_sel).upper() == "Y" else ""),
            "fobj_redate": r.get("fobj_redate") or "",
            "fobjreceipt_dt": r.get("fobjreceipt_dt") or "",
            "fobjection": objection_text,
            "flobjection": r.get("local_objection_text") or r.get("flobjection") or "",
            "fobjdescription": r.get("fobjdescription") or "",
        })

    json.dump(out, open(dst, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    summary = {
        "transform": "filing->case_objection",
        "filing_total": len(records),
        "emitted": len(out),
        "dropped_failed": dropped_failed,
        "dropped_no_cnr": dropped_no_cnr,
        "output": dst,
    }
    if summary_path:
        json.dump(summary, open(summary_path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    print(json.dumps(summary, ensure_ascii=False))


if __name__ == "__main__":
    main()
