#!/usr/bin/env python3
"""Transform process_generation output -> publish_process input.

The publish myval is deployment/table-specific, so this transform does not guess it.
It carries CNR/date/process hints; publish_process_cis_bridge discovers the myval
from publish_notice_ajax.php x=publish_table.
"""
import datetime as dt
import json
import sys


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: transform_process_generation_to_publish_process.py <process_generation_output.json> <publish_process_input.json> [summary.json]")
    src, dst = sys.argv[1], sys.argv[2]
    summary_path = sys.argv[3] if len(sys.argv) > 3 else None
    records = json.load(open(src, encoding="utf-8"))
    if not isinstance(records, list):
        sys.exit("process_generation output must be a JSON array")
    today = dt.date.today().strftime("%d-%m-%Y")
    out = []
    dropped_failed = dropped_no_cnr = 0
    for r in records:
        if not isinstance(r, dict) or r.get("status") != "success":
            dropped_failed += 1
            continue
        cnr = r.get("cis_cnr")
        if not cnr:
            dropped_no_cnr += 1
            continue
        hint = r.get("publish_discovery_hint") or {}
        out.append({
            "external_id": (r.get("external_id") or "publish") + f"-publish-{r.get('task_index') or len(out)+1}",
            "action": "publish",
            "cis_cnr": cnr,
            "ftype_of_filing": str(hint.get("ftype_of_filing") or r.get("case_radio") or "3"),
            "esigned": "N",
            "from_date": str(hint.get("from_date") or today),
            "to_date": str(hint.get("to_date") or today),
            "draft_date": str(hint.get("from_date") or today),
            "bunchprocessno": f"{cnr}~{r.get('process_no')}" if r.get("process_no") else "",
            "process_no": str(r.get("process_no") or ""),
            "rec_no": str(r.get("rec_no") or ""),
            "process_year": str(r.get("process_year") or ""),
            "postcheck": True
        })
    json.dump(out, open(dst, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    summary = {
        "transform": "process_generation->publish_process",
        "process_generation_total": len(records),
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
