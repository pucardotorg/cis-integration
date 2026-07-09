#!/usr/bin/env python3
"""HAR fixture checks for enriched case-proceeding prefetch parsers."""
from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parent
sys.path.insert(0, str(ROOT / "source"))

import cis_stage_fetchers as fetchers  # noqa: E402
import prefetch_case_data  # noqa: E402


def har_json(path: Path, entry: int) -> dict:
    with path.open(encoding="utf-8") as fh:
        har = json.load(fh)
    raw = har["log"]["entries"][entry]["response"]["content"]["text"].strip()
    return json.loads(raw)


class PrefetchInputTest(unittest.TestCase):
    def test_simplified_prefetch_record_expands_to_existing_contract(self) -> None:
        record = prefetch_case_data._simplify_record({"id": "trial10", "cnr": "HRPK030049362021", "stages": "registration,proceeding"})
        self.assertEqual(record["external_id"], "trial10")
        self.assertEqual(record["cis_cnr"], "HRPK030049362021")
        self.assertEqual(record["target_stages"], ["registration", "proceeding"])
        self.assertEqual(prefetch_case_data._record_stages(record, None), ["registration", "case_proceeding"])


class CaseProceedingHarParserTest(unittest.TestCase):
    def setUp(self) -> None:
        self.har = REPO / "har" / "proceeding" / "fetch_proceed.har"
        self.save_har = REPO / "har" / "proceeding" / "proceed_save.har"

    def test_fetch_har_extracts_non_appearance_panels(self) -> None:
        fetchdata = har_json(self.har, 67)
        appearance = har_json(self.har, 72)
        parties = har_json(self.har, 74)
        fetchparty = har_json(self.save_har, 1)
        delay = har_json(self.har, 77)
        status313 = har_json(self.har, 71)

        self.assertEqual(fetchdata["purpose_next"], 101)
        self.assertEqual(fetchdata["purpose_name"], "NON BAILABLE WARRANT OF ACCUSED")

        appearance_rows = fetchers._parse_appearance_rows(appearance["table_cases"])
        self.assertEqual(len(appearance_rows), 2)
        self.assertEqual(appearance_rows[0]["appearance_party_no"], "0")
        self.assertEqual(appearance_rows[1]["party_name"], "sanjay kumar pandey")
        self.assertEqual(appearance_rows[1]["process_issue"], "3")
        self.assertEqual(appearance_rows[1]["process_issue_label"], "Summons")
        self.assertEqual(appearance_rows[1]["issue_date"], "10-08-2023")

        party_values = {p["value"] for p in fetchers._parse_present_party_options(parties["selectBox"], fetchparty["party_table"])}
        self.assertTrue({"MP", "MPA", "MR", "ER~1"}.issubset(party_values))

        delay_rows = fetchers._parse_previous_delay_rows(delay["partyname"])
        self.assertEqual(delay_rows[0]["reason"], "One or more accused absconding/not appearing")

        status_rows = fetchers._parse_status313_rows(status313["table_cases"])
        self.assertEqual([r["status_313"] for r in status_rows], ["1", "1"])

    def test_draft_keeps_current_and_next_listing_purpose_separate(self) -> None:
        fetchdata = har_json(self.har, 67)
        panels = {
            "fetchappearance": har_json(self.har, 72),
            "showparties": har_json(self.har, 74),
            "fetchparty": har_json(self.save_har, 1),
            "show_previous_delay": har_json(self.har, 77),
            "fetch313crpc": har_json(self.har, 71),
        }
        draft = fetchers._case_proceeding_draft({}, fetchdata, "HRPK030049362021", "07-07-2026", panels)
        self.assertNotIn("current_listing_purpose_code", draft)
        self.assertNotIn("current_listing_purpose_name", draft)
        self.assertNotIn("current_listing_subpurpose_code", draft)
        self.assertEqual(draft["next_listing_purpose_code"], "")
        self.assertNotIn("purpose_code", draft)
        self.assertEqual(draft["next_listing_subpurpose_code"], "")
        self.assertEqual(draft["_fetched"]["current_listing_purpose_code"], "101")
        self.assertEqual(draft["_fetched"]["current_listing_purpose_name"], "NON BAILABLE WARRANT OF ACCUSED")
        self.assertEqual(draft["_fetched"]["current_listing_subpurpose_code"], "0")
        self.assertEqual(draft["_fetched"]["display_delay_reason_flag"], "SHOW")
        self.assertEqual(len(draft["appearance_rows"]), 2)
        self.assertIn("party_presence_options", draft)
        self.assertNotIn("purpose_options", draft)
        self.assertEqual(draft["_fetched"]["previous_delay_reasons"][0]["reason"], "One or more accused absconding/not appearing")


if __name__ == "__main__":
    unittest.main()
