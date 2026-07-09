#!/usr/bin/env python3
"""
Transform allocation-stage output -> select-court input.

Reads cis-allocation-results.json and emits one record per distinct allocated court:
  { external_id, court_no, radio_flag, source_count, source_cis_cnrs }

This is intentionally court-level, not case-level. The old CIS "select court" call sets
session context. Later stages that process cases across multiple courts should either
process grouped by court or call the same select-court flow per record/group.

Usage:
  python3 transform_allocation_to_select_court.py <allocation_output.json> <select_court_input.json> [summary.json]
"""
import json
import sys
from collections import OrderedDict


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: transform_allocation_to_select_court.py <allocation_output.json> <select_court_input.json> [summary.json]")
    src, dst = sys.argv[1], sys.argv[2]
    summary_path = sys.argv[3] if len(sys.argv) > 3 else None

    records = json.load(open(src, encoding="utf-8"))
    if not isinstance(records, list):
        sys.exit("allocation output must be a JSON array")

    courts = OrderedDict()
    dropped_failed = 0
    dropped_no_court = 0
    for r in records:
        if not isinstance(r, dict):
            dropped_failed += 1
            continue
        if r.get("status") != "success":
            dropped_failed += 1
            continue
        court = r.get("allocated_court_no") or r.get("target_court_no") or r.get("court_no")
        if court in (None, ""):
            dropped_no_court += 1
            continue
        court = str(court)
        if court not in courts:
            courts[court] = {
                "external_id": f"court-{court}",
                "court_no": court,
                "radio_flag": "active",
                "source_count": 0,
                "source_cis_cnrs": [],
            }
        courts[court]["source_count"] += 1
        cnr = r.get("cis_cnr")
        if cnr:
            courts[court]["source_cis_cnrs"].append(str(cnr))

    out = list(courts.values())
    json.dump(out, open(dst, "w", encoding="utf-8"), ensure_ascii=False, indent=2)

    summary = {
        "transform": "allocation->select_court",
        "allocation_total": len(records),
        "emitted": len(out),
        "dropped_failed": dropped_failed,
        "dropped_no_court": dropped_no_court,
        "output": dst,
    }
    if summary_path:
        json.dump(summary, open(summary_path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    print(json.dumps(summary, ensure_ascii=False))


if __name__ == "__main__":
    main()
