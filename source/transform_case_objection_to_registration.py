#!/usr/bin/env python3
"""
Transform case-objection output -> registration input.

Only successful no-objection/cleared records are emitted by default. Objection records
(fobj_sel=Y) are dropped because they should not be registered until cured.

Usage:
  python3 transform_case_objection_to_registration.py <case_objection_output.json> <registration_input.json> [summary.json]
"""
import datetime
import json
import sys


def normalized_acts(record):
    default_act = {
        "act_display": "Negotiable Instruments Act-732",
        "hidden_act_code": "18810260099001",
        "act_code": "732",
        "section_code": "138",
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
        sys.exit("usage: transform_case_objection_to_registration.py <case_objection_output.json> <registration_input.json> [summary.json]")
    src, dst = sys.argv[1], sys.argv[2]
    summary_path = sys.argv[3] if len(sys.argv) > 3 else None
    records = json.load(open(src, encoding="utf-8"))
    if not isinstance(records, list):
        sys.exit("case-objection output must be a JSON array")

    today = datetime.date.today().strftime("%d-%m-%Y")
    year = datetime.date.today().strftime("%Y")
    out = []
    dropped_failed = dropped_objection = dropped_no_cnr = 0
    for r in records:
        if not isinstance(r, dict) or r.get("status") != "success":
            dropped_failed += 1
            continue
        if str(r.get("fobj_sel") or "N").upper() == "Y":
            dropped_objection += 1
            continue
        cnr = r.get("cis_cnr") or r.get("ffiling_no")
        if not cnr:
            dropped_no_cnr += 1
            continue
        out.append({
            "external_id": r.get("external_id") or r.get("external_filing_id"),
            "cis_cnr": cnr,
            "cis_filing_no": r.get("cis_filing_no"),
            "fmm_case_type": str(r.get("fmm_case_type") or "55"),
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
            # Preserve organization and act metadata captured at filing; registration
            # can submit the org markers and all user-selected acts if showdetails omits them.
            "complainant_party_type": r.get("complainant_party_type"),
            "complainant_org_id": r.get("complainant_org_id"),
            "complainant_extra_count": r.get("complainant_extra_count"),
            "accused_party_type": r.get("accused_party_type"),
            "accused_org_id": r.get("accused_org_id"),
            "accused_extra_count": r.get("accused_extra_count"),
            "acts": normalized_acts(r),
            "registration_dt": r.get("registration_dt") or r.get("scrutiny_date") or today,
            "listing_dt": r.get("listing_dt") or r.get("next_listing_date") or r.get("scrutiny_date") or today,
            "purpose_code": str(r.get("purpose_code") or r.get("fpurpose_code") or "6"),
            "registration_year": str(r.get("registration_year") or year),
            "mode_of_filing": str(r.get("mode_of_filing") or "2"),
            "role": str(r.get("role") or "1"),
            # HAR final Register post carries all tab markers.
            "ftab_status": str(r.get("ftab_status") or "P~R~E~A~F"),
            "fdispactcode": r.get("fdispactcode") or ["Negotiable Instruments Act"],
            "fhiddactcode": r.get("fhiddactcode") or ["18810260099001 "],
            "factcode": r.get("factcode") or ["732"],
            "factsection_code": r.get("factsection_code") or ["138"],
        })

    json.dump(out, open(dst, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    summary = {
        "transform": "case_objection->registration",
        "case_objection_total": len(records),
        "emitted": len(out),
        "dropped_failed": dropped_failed,
        "dropped_objection": dropped_objection,
        "dropped_no_cnr": dropped_no_cnr,
        "output": dst,
    }
    if summary_path:
        json.dump(summary, open(summary_path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    print(json.dumps(summary, ensure_ascii=False))


if __name__ == "__main__":
    main()
