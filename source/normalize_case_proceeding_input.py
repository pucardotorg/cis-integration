#!/usr/bin/env python3
"""Normalize typed case-proceeding inputs into Data/case-proceeding-input.json.

This keeps operator-facing inputs separate by proceeding type (for example
next_hearing vs disposal) while preserving the flat input contract consumed by
source/case_proceeding_cis_bridge.sh.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_TYPES = ROOT / "Data" / "case-proceeding-types.json"
DEFAULT_OUTPUT = ROOT / "Data" / "case-proceeding-input.json"

DATE_FIELDS = {"proceeding_date", "next_hearing_date", "decision_date", "fdt_decision"}
TYPE_ALIASES = {
    "next": "next_hearing",
    "next-hearing": "next_hearing",
    "next_hearing": "next_hearing",
    "regular": "next_hearing",
    "adjournment": "next_hearing",
    "nbw": "non_bailable_warrant",
    "non-bailable-warrant": "non_bailable_warrant",
    "non_bailable_warrant": "non_bailable_warrant",
    "warrant": "non_bailable_warrant",
    "dispose": "disposal",
    "disposed": "disposal",
    "disposal": "disposal",
}


def load_json(path: Path) -> Any:
    try:
        with path.open(encoding="utf-8") as fh:
            return json.load(fh)
    except FileNotFoundError:
        raise SystemExit(f"input not found: {path}")
    except json.JSONDecodeError as exc:
        raise SystemExit(f"invalid JSON in {path}: {exc}")


def date_ddmmyyyy(value: Any) -> str:
    value = str(value or "").strip()
    if not value:
        return ""
    if re.match(r"^\d{2}-\d{2}-\d{4}$", value):
        return value
    match = re.match(r"^(\d{4})-(\d{2})-(\d{2})$", value)
    if match:
        return f"{match.group(3)}-{match.group(2)}-{match.group(1)}"
    raise ValueError(f"expected DD-MM-YYYY or YYYY-MM-DD, got {value!r}")


def is_truthy(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in {"1", "true", "yes", "y", "on"}


def norm_type(record: dict[str, Any]) -> str:
    raw = str(record.get("type") or record.get("proceeding_type") or "").strip().lower()
    if raw:
        return TYPE_ALIASES.get(raw, raw)
    if is_truthy(record.get("dispose_flag")) or record.get("decision_date") or record.get("disposal_type") or record.get("fdisp_type"):
        return "disposal"
    return "next_hearing"


def nonempty(value: Any) -> bool:
    return value is not None and value != "" and value != []


def merge_dicts(*parts: dict[str, Any]) -> dict[str, Any]:
    out: dict[str, Any] = {}
    for part in parts:
        for key, value in part.items():
            if key in {"example", "examples", "description", "required", "forbidden", "defaults", "fields", "aliases"}:
                continue
            out[key] = value
    return out


def types_map(catalogue: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
    common = catalogue.get("common", {}) if isinstance(catalogue.get("common"), dict) else {}
    tmap = catalogue.get("types", catalogue)
    if not isinstance(tmap, dict):
        raise SystemExit("case-proceeding-types.json must contain an object or a 'types' object")
    return common, tmap


def normalize_record(record: dict[str, Any], idx: int, common: dict[str, Any], tmap: dict[str, Any]) -> dict[str, Any]:
    if not isinstance(record, dict):
        raise ValueError(f"record {idx}: expected object")
    ptype = norm_type(record)
    spec = tmap.get(ptype)
    if not isinstance(spec, dict):
        raise ValueError(f"record {idx}: unknown case proceeding type {ptype!r}")

    merged = merge_dicts(
        common.get("defaults", {}) if isinstance(common.get("defaults"), dict) else {},
        spec.get("defaults", {}) if isinstance(spec.get("defaults"), dict) else {},
        record,
    )
    merged["type"] = ptype

    # Canonical aliases used by the bridge.
    if "fdt_decision" in merged and not merged.get("decision_date"):
        merged["decision_date"] = merged["fdt_decision"]
    if "fdisp_type" in merged and not merged.get("disposal_type"):
        merged["disposal_type"] = merged["fdisp_type"]
    if "radio_disp_type" in merged and not merged.get("disposal_radio_type"):
        merged["disposal_radio_type"] = merged["radio_disp_type"]
    if not merged.get("court_no"):
        for alias in ("fcourt_no", "target_court_no", "allocated_court_no"):
            if merged.get(alias):
                merged["court_no"] = merged[alias]
                break

    for field in DATE_FIELDS:
        if field in merged and nonempty(merged[field]):
            merged[field] = date_ddmmyyyy(merged[field])

    if ptype == "disposal":
        merged["dispose_flag"] = True
        merged["dormant_flag"] = str(merged.get("dormant_flag") or "D")
        merged["next_hearing_date"] = ""
        merged.setdefault("disposal_radio_type", "2")
    elif ptype == "next_hearing":
        merged["dispose_flag"] = False
    elif ptype == "non_bailable_warrant":
        merged["dispose_flag"] = False
        merged.setdefault("purpose_code", "101")
        merged["type"] = "next_hearing"

    required = list(spec.get("required", []))
    missing = [field for field in required if not nonempty(merged.get(field))]
    if missing:
        raise ValueError(f"record {idx} ({ptype}): missing required field(s): {', '.join(missing)}")

    forbidden = list(spec.get("forbidden", []))
    present_forbidden = [field for field in forbidden if nonempty(record.get(field))]
    if present_forbidden:
        raise ValueError(f"record {idx} ({ptype}): forbidden for this type: {', '.join(present_forbidden)}")

    if ptype == "disposal" and not is_truthy(merged.get("dispose_flag")):
        raise ValueError(f"record {idx} (disposal): dispose_flag must be true")
    if ptype in {"next_hearing", "non_bailable_warrant"} and not merged.get("next_hearing_date"):
        raise ValueError(f"record {idx} ({ptype}): next_hearing_date is required")

    # Do not pass catalogue-only keys downstream.
    for key in ("proceeding_type",):
        merged.pop(key, None)
    return merged


def normalize(input_path: Path, output_path: Path, types_path: Path) -> list[dict[str, Any]]:
    catalogue = load_json(types_path)
    if not isinstance(catalogue, dict):
        raise SystemExit("case proceeding types catalogue must be an object")
    common, tmap = types_map(catalogue)

    raw = load_json(input_path)
    records = raw if isinstance(raw, list) else raw.get("records") if isinstance(raw, dict) else None
    if not isinstance(records, list):
        raise SystemExit("typed case proceeding input must be a JSON array or {'records': [...]}")

    out: list[dict[str, Any]] = []
    errors: list[str] = []
    for i, record in enumerate(records, 1):
        try:
            out.append(normalize_record(record, i, common, tmap))
        except Exception as exc:  # collect all record errors for operator convenience
            errors.append(str(exc))
    if errors:
        raise SystemExit("case proceeding input validation failed:\n- " + "\n- ".join(errors))

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8") as fh:
        json.dump(out, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    return out


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="typed input JSON, e.g. Data/case-proceeding-disposal-input.json")
    parser.add_argument("output", type=Path, nargs="?", default=DEFAULT_OUTPUT, help="normalized output JSON")
    parser.add_argument("--types", type=Path, default=DEFAULT_TYPES, help="case proceeding types catalogue")
    args = parser.parse_args(argv)

    records = normalize(args.input, args.output, args.types)
    counts: dict[str, int] = {}
    for record in records:
        counts[record.get("type", "") or "unknown"] = counts.get(record.get("type", "") or "unknown", 0) + 1
    summary = ", ".join(f"{k}={v}" for k, v in sorted(counts.items())) or "no records"
    print(f"Wrote {len(records)} normalized case proceeding record(s) to {args.output} ({summary})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
