#!/usr/bin/env python3
"""
Extract a registration final-submit body from a HAR into a bridge input JSON record.

Why: normal bridge input is minimal and the bridge regenerates the browser form from
registration showdetails. For debugging/exact replay, this tool stores the raw
application/x-www-form-urlencoded body under `cis_form_urlencoded`; the registration
bridge will post that exact body if present.

Usage:
  python tools/extract_har_registration_input.py ../../walkthro-23062026/168.144.70.80.har Data/registration-exact-input.json
"""
import json
import re
import sys
from pathlib import Path
from urllib.parse import parse_qsl, unquote_plus


def first_json(s):
    m = re.search(r"\{.*\}", s or "", re.S)
    if not m:
        return {}
    try:
        return json.loads(m.group(0))
    except Exception:
        return {}


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    har_path = Path(sys.argv[1])
    out_path = Path(sys.argv[2])
    har = json.load(open(har_path, encoding="utf-8", errors="replace"))

    candidates = []
    for i, e in enumerate(har["log"]["entries"]):
        req = e.get("request", {})
        if req.get("method") != "POST" or "registration/registrationajax.php" not in req.get("url", ""):
            continue
        post = req.get("postData", {})
        text = post.get("text") or ""
        params = post.get("params") or []
        pairs = parse_qsl(text, keep_blank_values=True) if text else [(unquote_plus(p.get("name", "")), unquote_plus(p.get("value", ""))) for p in params]
        if any(k == "flag" and v == "Register" for k, v in pairs):
            candidates.append((i, e, text, pairs))

    if not candidates:
        raise SystemExit("No registration final-submit (flag=Register) found in HAR")

    i, e, text, pairs = candidates[-1]
    d = {}
    for k, v in pairs:
        # last-value view is fine for metadata; raw body preserves duplicates/order.
        d[k] = v
    resp = first_json(e.get("response", {}).get("content", {}).get("text", ""))
    record = {
        "external_id": f"HAR-registration-entry-{i}",
        "cis_cnr": d.get("ffiling_no"),
        "cis_filing_no_numeric": d.get("filingno"),
        "fmm_case_type": d.get("ffilcase_type") or d.get("fcase_type_reg") or "55",
        "fci_cri": d.get("fci_cri") or "3",
        "registration_dt": d.get("fdt_regis"),
        "listing_dt": d.get("flisting_date"),
        "purpose_code": d.get("fpurpose_code"),
        "registration_year": d.get("freg_year"),
        "mode_of_filing": d.get("mode_of_filing"),
        "role": d.get("role"),
        "ftab_status": d.get("ftab_status"),
        "expected_submit_response": resp,
        "cis_form_urlencoded": text or "&".join(f"{k}={v}" for k, v in pairs),
    }
    json.dump([record], open(out_path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    print(f"Extracted HAR entry {i} to {out_path}")


if __name__ == "__main__":
    main()
