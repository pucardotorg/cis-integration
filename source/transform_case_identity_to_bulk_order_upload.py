#!/usr/bin/env python3
"""
Transform case_identity prefetch output -> bulk_order_upload input.

For cases registered OUTSIDE this tool (no registration stage output). Reads the
long registered case_no + cis_filing_no + pet_name resolved by the case_identity
prefetch stage, and joins operator-supplied order PDF details from
Data/bulk-order-upload-drafts.json (keyed by external_id).

case_no is the *internal registered case number* (all digits, e.g.
205500000112026) that bulkupload.php validates against -- never the display
label 'NACT/11/2026', which the server rejects.

Usage:
  python3 transform_case_identity_to_bulk_order_upload.py \
      <case_identity_input.json> <bulk_order_upload_input.json> [summary.json]
"""
import datetime
import json
import sys
from pathlib import Path

DRAFTS_PATH = Path(__file__).resolve().parents[1] / "Data" / "bulk-order-upload-drafts.json"


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: transform_case_identity_to_bulk_order_upload.py "
                 "<case_identity_input.json> <bulk_order_upload_input.json> [summary.json]")
    src, dst = sys.argv[1], sys.argv[2]
    summary_path = sys.argv[3] if len(sys.argv) > 3 else None

    records = json.load(open(src, encoding="utf-8"))
    if not isinstance(records, list):
        sys.exit("case_identity input must be a JSON array")

    drafts = []
    if DRAFTS_PATH.exists():
        drafts = json.load(open(DRAFTS_PATH, encoding="utf-8"))
        if not isinstance(drafts, list):
            sys.exit(f"{DRAFTS_PATH} must be a JSON array")
    drafts_by_id = {}
    for d in drafts:
        if isinstance(d, dict) and d.get("external_id"):
            drafts_by_id.setdefault(d["external_id"], d)

    today = datetime.date.today().strftime("%d-%m-%Y")
    out = []
    dropped_no_cnr = dropped_no_case_no = dropped_no_draft = dropped_no_pdf = 0
    for r in records:
        if not isinstance(r, dict):
            continue
        ext = r.get("external_id") or r.get("external_filing_id")
        cnr = r.get("cis_cnr") or r.get("cino")
        case_no = str(r.get("case_no") or "")
        if not cnr:
            dropped_no_cnr += 1
            continue
        if not case_no:
            dropped_no_case_no += 1
            continue

        draft = drafts_by_id.get(ext, {})
        if not draft:
            dropped_no_draft += 1
            continue
        file_path = draft.get("file_path") or ""
        if not file_path:
            dropped_no_pdf += 1
            continue

        out.append({
            "external_id": ext,
            "cis_cnr": cnr,
            "cis_filing_no": r.get("cis_filing_no") or "",
            "case_no": case_no,
            "pet_name": r.get("pet_name") or "",
            "file_path": file_path,
            "document_type": str(draft.get("document_type") or ""),
            "order_no": str(draft.get("order_no") or ""),
            "order_date": draft.get("order_date") or today,
        })

    json.dump(out, open(dst, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    summary = {
        "transform": "case_identity->bulk_order_upload",
        "case_identity_total": len(records),
        "drafts_total": len(drafts),
        "emitted": len(out),
        "dropped_no_cnr": dropped_no_cnr,
        "dropped_no_case_no": dropped_no_case_no,
        "dropped_no_draft": dropped_no_draft,
        "dropped_no_pdf": dropped_no_pdf,
        "drafts_manifest": str(DRAFTS_PATH),
        "output": dst,
    }
    if summary_path:
        json.dump(summary, open(summary_path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    print(json.dumps(summary, ensure_ascii=False))


if __name__ == "__main__":
    main()
