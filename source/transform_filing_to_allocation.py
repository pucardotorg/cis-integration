#!/usr/bin/env python3
"""
Transform filing-stage output -> allocation-stage input (Option A passthrough).

Reads the filing bridge output (cis-results.json): an array of records, each like
  { external_filing_id, status, cis_cnr, fmm_case_type, target_court_no, ... }
Emits an allocation input array:
  { external_id, cis_cnr, fmm_case_type, target_court_no, allocation_dt }

Failed filing records are dropped (listed in the summary, not emitted).
Records missing cis_cnr or target_court_no are dropped with a reason.

Usage:
  python3 transform_filing_to_allocation.py <filing_output.json> <allocation_input.json> [summary.json]
Prints a JSON summary to stdout.
"""
import json, sys, datetime


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: transform_filing_to_allocation.py <filing_output.json> <allocation_input.json> [summary.json]")
    src, dst = sys.argv[1], sys.argv[2]
    summary_path = sys.argv[3] if len(sys.argv) > 3 else None

    records = json.load(open(src, encoding="utf-8"))
    if not isinstance(records, list):
        sys.exit("filing output must be a JSON array")

    today = datetime.date.today().strftime("%d-%m-%Y")
    out = []
    dropped_failed = 0
    dropped_no_cnr = 0
    dropped_no_court = 0
    for r in records:
        if r.get("status") != "success":
            dropped_failed += 1
            continue
        cnr = r.get("cis_cnr")
        if not cnr:
            dropped_no_cnr += 1
            continue
        court = r.get("target_court_no")
        if not court:
            dropped_no_court += 1
            continue
        out.append({
            "external_id": r.get("external_filing_id") or r.get("external_id"),
            "cis_cnr": cnr,
            "fmm_case_type": str(r.get("fmm_case_type") or "55"),
            "target_court_no": str(court),
            "allocation_dt": r.get("allocation_dt") or today,
            # HAR 168.144.70.80 allocation submit included purpose + next date.
            "next_date": r.get("next_date") or r.get("listing_dt") or r.get("allocation_dt") or today,
            "purpose_code": str(r.get("purpose_code") or r.get("fpurpose_code") or "6"),
        })

    json.dump(out, open(dst, "w", encoding="utf-8"), ensure_ascii=False, indent=2)

    summary = {
        "transform": "filing->allocation",
        "filing_total": len(records),
        "emitted": len(out),
        "dropped_failed": dropped_failed,
        "dropped_no_cnr": dropped_no_cnr,
        "dropped_no_court": dropped_no_court,
        "output": dst,
    }
    if summary_path:
        json.dump(summary, open(summary_path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    print(json.dumps(summary, ensure_ascii=False))


if __name__ == "__main__":
    main()
