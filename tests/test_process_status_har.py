#!/usr/bin/env python3
"""HAR-backed checks for process status parsing."""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parent
BRIDGE = ROOT / "source" / "process_status_fetch_cis_bridge.sh"
HAR = REPO / "har" / "process status.har"


def _bridge_python_source() -> str:
    s = BRIDGE.read_text(encoding="utf-8")
    start = s.index("import html, json, re, subprocess, sys")
    end = s.index("json.dump(results, open(output_json", start)
    return s[start:end] + "\n"


class ProcessStatusHarTest(unittest.TestCase):
    def test_parser_extracts_clean_fields_from_har_row(self) -> None:
        har = json.loads(HAR.read_text(encoding="utf-8"))
        raw = har["log"]["entries"][82]["response"]["content"]["text"]
        payload = json.loads(raw[raw.index("{"): raw.rindex("}") + 1])
        row = payload["aaData"][0]

        ns = {}
        with tempfile.TemporaryDirectory() as td:
            inp = Path(td) / "in.json"
            inp.write_text("[]", encoding="utf-8")
            sys.argv = ["inline", str(inp), "out.json", "cookie", "http://127.0.0.1/swecourtis", "08-07-2026"]
            exec(_bridge_python_source(), ns)
        parsed = ns["extract_row"](row)

        self.assertEqual(parsed["case_number"], "NACT/1087/2019")
        self.assertEqual(parsed["cis_cnr"], "HRPK030052342019")
        self.assertEqual(parsed["process_id"], "PHRPK030052342019_13_2")
        self.assertEqual(parsed["next_date"], "05-08-2026")
        self.assertEqual(parsed["type_of_process"], "Bailable Warrant")
        self.assertEqual(parsed["date_of_publishing"], "03-07-2026")
        self.assertEqual(parsed["status_of_service"], "Pending")

    def test_bridge_shell_syntax(self) -> None:
        subprocess.run(["bash", "-n", str(BRIDGE)], check=True)


if __name__ == "__main__":
    unittest.main()
