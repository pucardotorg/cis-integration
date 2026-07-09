#!/usr/bin/env python3
"""
Transform registration output -> bulk_order_upload input.

Auto-populates case identity from the registration stage so the upload payload
always carries the *internal registered case number* (registered_case_number)
that bulkupload.php validates against -- never the human display label
(registered_case_label, e.g. 'NACT/11/2026') which the server rejects with the
opaque 'not uploaded' string.

Case identity (auto, from registration):
  external_id, cis_cnr, case_no (=registered_case_number),
  cis_filing_no (=showdetails.filing_no), pet_name (=showdetails.pet_name),
  registered_case_label

Order-specific fields (user-maintained, from Data/bulk-order-upload-drafts.json,
keyed by external_id -- the order PDF is produced outside this pipeline):
  file_path, document_type, order_no, order_date

Court selection is handled by each bridge from Data/config.json COURT_NO.

Usage:
  python3 transform_registration_to_bulk_order_upload.py \
      <registration_output.json> <bulk_order_upload_input.json> [summary.json]
"""
import datetime
import json
import sys
from pathlib import Path

# Drafts manifest lives alongside the other Data/ step inputs. Resolve it from
# this script's location (source/ -> ../Data/bulk-order-upload-drafts.json) so the
# transform works regardless of the caller's cwd.
DRAFTS_PATH = Path(__file__).resolve().parents[1] / "Data" / "bulk-order-upload-drafts.json"


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: transform_registration_to_bulk_order_upload.py "
                 "<registration_output.json> <bulk_order_upload_input.json> [summary.json]")
    src, dst = sys.argv[1], sys.argv[2]
    summary_path = sys.argv[3] if len(sys.argv) > 3 else None

    records = json.load(open(src, encoding="utf-8"))
    if not isinstance(records, list):
        sys.exit("registration output must be a JSON array")

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
    dropped_failed = dropped_no_cnr = dropped_no_draft = dropped_no_pdf = 0
    for r in records:
        if not isinstance(r, dict) or r.get("status") != "success":
            dropped_failed += 1
            continue
        ext = r.get("external_id") or r.get("external_filing_id")
        cnr = r.get("cis_cnr") or r.get("ffiling_no")
        registered_no = r.get("registered_case_number")
        if not cnr or not registered_no:
            dropped_no_cnr += 1
            continue

        draft = drafts_by_id.get(ext, {})
        if not draft:
            dropped_no_draft += 1
            continue
        file_path = draft.get("file_path") or ""
        if not file_path:
            dropped_no_pdf += 1
            continue

        sd = r.get("showdetails_response") or {}
        out.append({
            "external_id": ext,
            "cis_cnr": cnr,
            "cis_filing_no": sd.get("filing_no") or r.get("cis_filing_no") or "",
            # CRITICAL: the internal registered case number, not the display label.
            "case_no": str(registered_no),
            "registered_case_label": r.get("registered_case_label") or "",
            "pet_name": sd.get("pet_name") or r.get("pet_name") or "",
            "file_path": file_path,
            "document_type": str(draft.get("document_type") or ""),
            "order_no": str(draft.get("order_no") or ""),
            "order_date": draft.get("order_date") or today,
        })

    json.dump(out, open(dst, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    summary = {
        "transform": "registration->bulk_order_upload",
        "registration_total": len(records),
        "drafts_total": len(drafts),
        "emitted": len(out),
        "dropped_failed_registration": dropped_failed,
        "dropped_no_cnr": dropped_no_cnr,
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
