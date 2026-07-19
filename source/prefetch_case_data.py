#!/usr/bin/env python3
"""Multi-record read-only CIS prefetch.

Contract:
  login -> extract read-only stage data -> transform to uploader JSON -> save -> logout

This script writes draft JSON inputs for registration and case_proceeding. It does
not submit to CIS. Existing submit bridges must still re-fetch before writing.

Input can be concise; each item may be a CNR string or an object like:
  {"id": "trial10", "cnr": "HRPK...", "filing": "NACT/40/2026", "stages": "proceeding"}
Court selection is performed once after login, before any prefetch reads, unless
SKIP_COURT_SELECTION=true.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
import tempfile
from pathlib import Path
from typing import Callable

from cis_fetch_common import CisError, CisSession, load_config
from cis_stage_fetchers import fetch_case_proceeding, fetch_case_identity, fetch_registration

STAGE_ALIASES = {
    "registration": "registration",
    "register": "registration",
    "reg": "registration",
    "case_proceeding": "case_proceeding",
    "case-proceeding": "case_proceeding",
    "proceeding": "case_proceeding",
    "proceedings": "case_proceeding",
    "processing": "case_proceeding",
    "case_identity": "case_identity",
    "case-identity": "case_identity",
    "identity": "case_identity",
    "case_id": "case_identity",
}
DEFAULT_STAGES = ["registration", "case_proceeding"]
STAGE_ORDER = {"registration": 0, "case_proceeding": 1, "case_identity": 0}


def _now_iso() -> str:
    return dt.datetime.now().astimezone().replace(microsecond=0).isoformat()


def _rel(root: Path, path: Path) -> str:
    try:
        return path.resolve().relative_to(root.resolve()).as_posix()
    except Exception:
        return path.as_posix()


def _resolve(root: Path, value: str | os.PathLike[str]) -> Path:
    p = Path(value)
    if p.is_absolute():
        return p
    return root / p


def _load_records(path: Path) -> list[dict]:
    data = json.load(open(path, encoding="utf-8"))
    if isinstance(data, dict) and isinstance(data.get("records"), list):
        data = data["records"]
    if not isinstance(data, list):
        raise SystemExit(f"input must be a JSON array or {{'records': [...]}}: {path}")
    out: list[dict] = []
    for idx, item in enumerate(data):
        if isinstance(item, str):
            item = {"cis_cnr": item}
        if not isinstance(item, dict):
            raise SystemExit(f"input[{idx}] must be an object or CNR string")
        out.append(_simplify_record(item))
    return out


def _write_json(path: Path, data: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    tmp.replace(path)


def _split_stage_tokens(value: object) -> list[str]:
    if value in (None, ""):
        return []
    if isinstance(value, str):
        return [s.strip() for s in value.replace("+", ",").split(",") if s.strip()]
    if isinstance(value, list):
        return [str(s).strip() for s in value if str(s).strip()]
    raise ValueError("stages must be an array or comma-separated string")


def _simplify_record(record: dict) -> dict:
    """Accept short prefetch inputs and expand them to the existing contract.

    Supported concise forms:
      {"cnr": "...", "stages": "proceeding"}
      {"case": "...", "stage": "registration"}
      "HRPK..."  (handled by _load_records)
    Existing verbose keys still win.
    """
    out = dict(record)
    if "external_id" not in out and out.get("id"):
        out["external_id"] = str(out.get("id"))
    identifier = out.get("identifier") or out.get("case") or out.get("case_id") or out.get("cnr") or out.get("cino") or out.get("cis_cnr")
    if identifier and not out.get("cis_cnr"):
        out["cis_cnr"] = str(identifier)
    filing = out.get("filing") or out.get("filing_no") or out.get("cis_filing_no")
    if filing and not out.get("cis_filing_no"):
        out["cis_filing_no"] = str(filing)
    if "target_stages" not in out:
        stages = out.get("stages", out.get("stage", out.get("target_stage")))
        tokens = _split_stage_tokens(stages)
        if tokens:
            out["target_stages"] = tokens
    return out


def _normalise_stage_name(stage: str) -> str:
    key = str(stage or "").strip().lower()
    if key not in STAGE_ALIASES:
        raise ValueError(f"unknown prefetch stage: {stage}")
    return STAGE_ALIASES[key]


def _record_stages(record: dict, cli_stages: list[str] | None) -> list[str]:
    raw = cli_stages if cli_stages is not None else record.get("target_stages")
    tokens = _split_stage_tokens(raw)
    if not tokens:
        return list(DEFAULT_STAGES)
    stages: list[str] = []
    for s in tokens:
        normal = _normalise_stage_name(str(s))
        if normal not in stages:
            stages.append(normal)
    return stages or list(DEFAULT_STAGES)


def _external_id(record: dict, idx: int) -> str:
    return str(record.get("external_id") or record.get("external_filing_id") or record.get("cis_cnr") or record.get("cnr") or f"prefetch-{idx+1}")


def _cnr(record: dict) -> str:
    return str(record.get("cis_cnr") or record.get("cnr") or record.get("cino") or record.get("ffiling_no") or "")


def _stage_error(exc: Exception) -> dict:
    if isinstance(exc, CisError):
        return {"status": "failed", "error": exc.to_dict()}
    return {"status": "failed", "error": {"code": "unexpected_error", "message": str(exc)}}


def _trim_stage_audit(stage_result: dict, include_raw: bool) -> dict:
    out = {
        "status": stage_result.get("status", "prefetched"),
        "cis_cnr": stage_result.get("cis_cnr"),
    }
    draft = stage_result.get("draft") or {}
    if isinstance(draft, dict):
        out["draft_summary"] = {
            "external_id": draft.get("external_id"),
            "cis_cnr": draft.get("cis_cnr"),
        }
        if "complainant_name" in draft or "accused_name" in draft:
            out["draft_summary"].update({
                "complainant_name": draft.get("complainant_name"),
                "accused_name": draft.get("accused_name"),
                "registration_date": draft.get("registration_date"),
                "listing_date": draft.get("listing_date"),
            })
        if "proceeding_date" in draft:
            out["draft_summary"].update({
                "proceeding_date": draft.get("proceeding_date"),
                "next_hearing_date": draft.get("next_hearing_date"),
                "next_listing_purpose_code": draft.get("next_listing_purpose_code"),
            })
        if "case_no" in draft and "cis_filing_no" in draft:
            out["draft_summary"].update({
                "case_no": draft.get("case_no"),
                "cis_filing_no": draft.get("cis_filing_no"),
                "pet_name": draft.get("pet_name"),
            })
    fetched = stage_result.get("fetched") or {}
    if isinstance(fetched, dict):
        out["fetched"] = fetched if include_raw else {"page_form_fields": fetched.get("page_form_fields")}
    return out


def prefetch(records: list[dict], root: Path, cli_stages: list[str] | None, include_raw: bool) -> tuple[list[dict], list[dict], list[dict], list[dict]]:
    config = load_config(root)
    registration_records: list[dict] = []
    proceeding_records: list[dict] = []
    identity_records: list[dict] = []
    audit: list[dict] = []

    print(f"CIS URL: {config.base_url}", file=sys.stderr)
    print(f"Court code: {config.court_code}", file=sys.stderr)
    print(f"Court no: {config.court_no}", file=sys.stderr)
    print(f"Skip court selection: {config.skip_court_selection}", file=sys.stderr)
    print(f"Input records: {len(records)}", file=sys.stderr)
    if not records:
        print("No input records; writing empty prefetch outputs without CIS login.", file=sys.stderr)
        return registration_records, proceeding_records, identity_records, audit

    session = CisSession(config)
    print("Logging in to CIS...", file=sys.stderr)
    session.login()
    print("CIS login complete.", file=sys.stderr)
    try:
        court_selection = session.select_court_if_enabled(stage="prefetch")
        print(f"Court selection: {court_selection.get('status')} court_no={court_selection.get('court_no')}", file=sys.stderr)
    except Exception:
        session.logout()
        raise
    try:
        fetchers: dict[str, Callable[[CisSession, dict], dict]] = {
            "registration": fetch_registration,
            "case_proceeding": fetch_case_proceeding,
            "case_identity": fetch_case_identity,
        }
        for idx, record in enumerate(records):
            ext = _external_id(record, idx)
            cnr = _cnr(record)
            item_audit = {
                "index": idx,
                "external_id": ext,
                "cis_cnr": cnr,
                "requested_stages": [],
                "court_selection": court_selection,
                "started_at": _now_iso(),
            }
            try:
                stages = _record_stages(record, cli_stages)
            except Exception as exc:
                item_audit.update({"status": "failed", "error": {"code": "invalid_target_stages", "message": str(exc)}})
                audit.append(item_audit)
                continue

            item_audit["requested_stages"] = stages
            print(f"Prefetch [{idx+1}/{len(records)}] {ext} {cnr or ''}: {', '.join(stages)}", file=sys.stderr)
            successes = 0
            for stage in stages:
                try:
                    result = fetchers[stage](session, record)
                    draft = result.get("draft")
                    if stage == "registration" and isinstance(draft, dict):
                        registration_records.append(draft)
                        stage_audit = _trim_stage_audit(result, include_raw)
                        stage_audit["draft_record_index"] = len(registration_records) - 1
                    elif stage == "case_proceeding" and isinstance(draft, dict):
                        proceeding_records.append(draft)
                        stage_audit = _trim_stage_audit(result, include_raw)
                        stage_audit["draft_record_index"] = len(proceeding_records) - 1
                    elif stage == "case_identity" and isinstance(draft, dict):
                        identity_records.append(draft)
                        stage_audit = _trim_stage_audit(result, include_raw)
                        stage_audit["draft_record_index"] = len(identity_records) - 1
                    else:
                        stage_audit = {"status": "failed", "error": {"code": "missing_draft", "message": "fetcher did not return a draft object"}}
                    item_audit[stage] = stage_audit
                    if stage_audit.get("status") == "prefetched":
                        successes += 1
                except Exception as exc:
                    item_audit[stage] = _stage_error(exc)
            if successes == len(stages) and stages:
                item_audit["status"] = "success"
            elif successes:
                item_audit["status"] = "partial"
            else:
                item_audit["status"] = "failed"
            item_audit["finished_at"] = _now_iso()
            audit.append(item_audit)
    finally:
        print("Logging out of CIS...", file=sys.stderr)
        session.logout()
        print("CIS logout complete.", file=sys.stderr)

    return registration_records, proceeding_records, identity_records, audit


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Read-only CIS prefetch for registration/case_proceeding inputs")
    parser.add_argument("input_json", help="JSON array with CNR/filing identifiers")
    parser.add_argument("--root", default=str(Path(__file__).resolve().parents[1]), help="uploader/V3 root")
    parser.add_argument("--stages", default="", help="comma-separated stage filter: registration,case_proceeding")
    parser.add_argument("--registration-out", default="Data/registration-input.prefetched.json")
    parser.add_argument("--case-proceeding-out", default="Data/case-proceeding-input.prefetched.json")
    parser.add_argument("--case-identity-out", default="Data/case-identity-input.prefetched.json")
    parser.add_argument("--result-out", default=os.environ.get("PREFETCH_RESULT_JSON") or os.environ.get("OUTPUT_JSON") or "")
    parser.add_argument("--write-data", action="store_true", help="write canonical Data/*-input.json instead of *.prefetched.json")
    parser.add_argument("--include-raw", action="store_true", help="include raw read-AJAX JSON in audit output")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_arg_parser().parse_args(argv)
    root = Path(args.root).resolve()
    input_path = _resolve(root, args.input_json)
    reg_out = _resolve(root, args.registration_out)
    proc_out = _resolve(root, args.case_proceeding_out)
    id_out = _resolve(root, args.case_identity_out)
    if args.write_data:
        reg_out = root / "Data" / "registration-input.json"
        proc_out = root / "Data" / "case-proceeding-input.json"
        id_out = root / "Data" / "case-identity-input.json"

    result_out = _resolve(root, args.result_out) if args.result_out else None
    cli_stages = None
    if args.stages.strip():
        cli_stages = [_normalise_stage_name(s.strip()) for s in args.stages.split(",") if s.strip()]

    records = _load_records(input_path)
    registration_records, proceeding_records, identity_records, audit = prefetch(records, root, cli_stages, args.include_raw)

    wrote: list[str] = []
    # Write only requested/produced outputs. Empty arrays are still useful when a
    # user explicitly requested that stage, so always write all three default draft files.
    _write_json(reg_out, registration_records)
    wrote.append(_rel(root, reg_out))
    _write_json(proc_out, proceeding_records)
    wrote.append(_rel(root, proc_out))
    _write_json(id_out, identity_records)
    wrote.append(_rel(root, id_out))

    summary = {
        "kind": "prefetch_case_data",
        "input": _rel(root, input_path),
        "started_finished_at": _now_iso(),
        "registration_output": _rel(root, reg_out),
        "case_proceeding_output": _rel(root, proc_out),
        "case_identity_output": _rel(root, id_out),
        "registration_records": len(registration_records),
        "case_proceeding_records": len(proceeding_records),
        "case_identity_records": len(identity_records),
        "records": audit,
    }
    if result_out:
        _write_json(result_out, summary)
        wrote.append(_rel(root, result_out))

    print(json.dumps({
        "status": "complete",
        "input_records": len(records),
        "registration_records": len(registration_records),
        "case_proceeding_records": len(proceeding_records),
        "case_identity_records": len(identity_records),
        "wrote": wrote,
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
