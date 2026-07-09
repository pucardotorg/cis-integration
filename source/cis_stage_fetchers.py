#!/usr/bin/env python3
"""Read-only CIS stage fetchers and mappers for uploader/V3 prefetch.

Each fetcher performs only safe GET/read-AJAX calls, then transforms CIS output
into the readable JSON accepted by the existing submit bridges.  Submit bridges
must still re-fetch authoritative CIS state immediately before writing.
"""
from __future__ import annotations

import datetime as dt
import html as html_lib
import re
from typing import Any

from cis_fetch_common import CisError, CisSession, parse_form, parse_json_response

DEFAULT_REGISTRATION_LINKID = "74"
DEFAULT_REGISTRATION_MODE = "1"
DEFAULT_CASE_PROCEEDING_LINKID = "261"
DEFAULT_CASE_PROCEEDING_MODE = "0"


def _today_ddmmyyyy() -> str:
    return dt.date.today().strftime("%d-%m-%Y")


def _ddmmyyyy(value: Any, default: str = "") -> str:
    value = str(value or default or "")
    if re.match(r"^\d{2}-\d{2}-\d{4}$", value):
        return value
    match = re.match(r"^(\d{4})-(\d{2})-(\d{2})$", value)
    if match:
        return f"{match.group(3)}-{match.group(2)}-{match.group(1)}"
    return value


def _nonempty(value: Any) -> bool:
    return value is not None and value != ""


def _bool(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in {"1", "true", "yes", "y", "on"}


def _s(data: dict, *keys: str, default: Any = "") -> str:
    for key in keys:
        value = data.get(key)
        if _nonempty(value):
            return str(value)
    return str(default or "")


def _item(record: dict, *keys: str, default: Any = "") -> str:
    return _s(record, *keys, default=default)


def _identifier(record: dict) -> tuple[str, str]:
    """Return (cnr, filing_no_or_numeric) from readable aliases."""
    cnr = _item(record, "cis_cnr", "cnr", "cino", "ffiling_no")
    filing = _item(record, "cis_filing_no_numeric", "cis_filing_no", "filing_no", "filingno")
    return cnr, filing


def _external_id(record: dict, cnr: str, prefix: str = "CASE") -> str:
    return _item(record, "external_id", "external_filing_id", default=(f"{prefix}-{cnr}" if cnr else ""))


def _year_from_date(value: str) -> str:
    if value and "-" in value:
        return value.split("-")[-1]
    return dt.date.today().strftime("%Y")


def _registration_draft(record: dict, show: dict, appellate: dict, login_date: str) -> dict:
    cnr, filing = _identifier(record)
    filing = _item(record, "cis_filing_no_numeric", default=show.get("filing_no") or filing)
    reg_dt = _ddmmyyyy(_item(record, "registration_date", "registration_dt", "fdt_regis", default=_s(show, "dt_regis", "serverDate", default=login_date or _today_ddmmyyyy())))
    listing_dt = _ddmmyyyy(_item(record, "listing_date", "listing_dt", "flisting_date", default=_s(show, "date_next_list", "date_first_list", default=reg_dt)))
    case_type = _item(record, "case_type_code", "cis_case_type_code", "fmm_case_type", default=_s(show, "filcase_type", "case_type", default="55"))
    purpose = _item(record, "purpose_code", "fpurpose_code", default=_s(show, "purpose_next", default="6"))
    year = _item(record, "registration_year", "freg_year", default=_s(show, "reg_year", "sessionYear", default=_year_from_date(reg_dt)))

    draft = {
        "external_id": _external_id(record, cnr),
        "cis_cnr": cnr,
        "cis_filing_no_numeric": filing,
        "case_type_code": case_type,
        "case_type_name": _item(record, "case_type_name", default="NACT"),
        "ci_cri": _item(record, "ci_cri", "fci_cri", default=_s(show, "ci_cri", default="3")),
        "mode_of_filing": _item(record, "mode_of_filing", default=_s(appellate, "mode_of_filing", default="2")),
        "role": _item(record, "role", default="1"),
        "ftab_status": _item(record, "ftab_status", default=_s(show, "tab_status", default="P~R~E~A~F")),
        "registration_date": reg_dt,
        "registration_year": str(year),
        "listing_date": listing_dt,
        "purpose_code": str(purpose),

        "complainant_salutation": _s(show, "pet_salutation", default=_item(record, "complainant_salutation", default="1")),
        "complainant_name": _item(record, "complainant_name", "pet_name", "fpet_name", default=_s(show, "pet_name")),
        "complainant_local_name": _item(record, "complainant_local_name", "lpet_name", default=_s(show, "lpet_name", "pet_name")),
        "complainant_gender_code": _item(record, "complainant_gender_code", "pet_sex", default=_s(show, "pet_sex", default="1")),
        "complainant_age": _item(record, "complainant_age", "pet_age", default=_s(show, "pet_age")),
        "complainant_father_flag": _item(record, "complainant_father_flag", "pet_father_flag", default=_s(show, "pet_father_flag", default="1")),
        "complainant_father_name": _item(record, "complainant_father_name", "pet_father_name", default=_s(show, "pet_father_name")),
        "complainant_inperson": _item(record, "complainant_inperson", "pet_inperson", default=_s(show, "pet_inperson", default="Y")),
        "complainant_address": _item(record, "complainant_address", "petadd", default=_s(show, "petadd")),
        "complainant_local_address": _item(record, "complainant_local_address", "lpetadd", default=_s(show, "lpetadd", "petadd")),
        "complainant_email": _item(record, "complainant_email", "pet_email", default=_s(show, "pet_email")),
        "complainant_mobile": _item(record, "complainant_mobile", "pet_mobile", default=_s(show, "pet_mobile")),
        "complainant_pincode": _item(record, "complainant_pincode", "pet_pincode", default=_s(show, "pet_pincode")),
        "complainant_nationality": _item(record, "complainant_nationality", "pet_nationality", default=_s(show, "pet_nationality")),
        "complainant_state_code": _item(record, "complainant_state_code", "state_code_pet_off", default=_s(show, "state_code_pet_off", default="6")),
        "complainant_district_code": _item(record, "complainant_district_code", "dist_code_pet_off", default=_s(show, "dist_code_pet_off")),
        "complainant_taluka_code": _item(record, "complainant_taluka_code", "taluka_code_pet_off", default=_s(show, "taluka_code_pet_off")),
        "complainant_advocate_type": _item(record, "complainant_advocate_type", default="R"),
        "complainant_advocate_name": _item(record, "complainant_advocate_name", "pet_adv", default=_s(show, "pet_adv")),
        "complainant_advocate_barcode": _item(record, "complainant_advocate_barcode", "petbar_code", default=_s(show, "petbar_code")),
        "complainant_advocate_code": _item(record, "complainant_advocate_code", "pet_adv_cd", default=_s(show, "pet_adv_cd", default="0")),

        "accused_salutation": _s(show, "res_salutation", default=_item(record, "accused_salutation", default="1")),
        "accused_name": _item(record, "accused_name", "respondent_name", "res_name", "fres_name", default=_s(show, "res_name")),
        "accused_local_name": _item(record, "accused_local_name", "respondent_local_name", "lres_name", default=_s(show, "lres_name", "res_name")),
        "accused_gender_code": _item(record, "accused_gender_code", "respondent_gender_code", "res_sex", default=_s(show, "res_sex", default="1")),
        "accused_age": _item(record, "accused_age", "respondent_age", "res_age", default=_s(show, "res_age")),
        "accused_father_flag": _item(record, "accused_father_flag", "res_father_flag", default=_s(show, "res_father_flag", default="1")),
        "accused_father_name": _item(record, "accused_father_name", "res_father_name", default=_s(show, "res_father_name")),
        "accused_address": _item(record, "accused_address", "respondent_address", "resadd", default=_s(show, "resadd")),
        "accused_local_address": _item(record, "accused_local_address", "respondent_local_address", "lresadd", default=_s(show, "lresadd", "resadd")),
        "accused_email": _item(record, "accused_email", "respondent_email", "res_email", default=_s(show, "res_email")),
        "accused_mobile": _item(record, "accused_mobile", "respondent_mobile", "res_mobile", default=_s(show, "res_mobile")),
        "accused_pincode": _item(record, "accused_pincode", "respondent_pincode", "res_pincode", default=_s(show, "res_pincode")),
        "accused_nationality": _item(record, "accused_nationality", "respondent_nationality", "res_nationality", default=_s(show, "res_nationality")),
        "accused_state_code": _item(record, "accused_state_code", "state_code_res_off", default=_s(show, "state_code_res_off", default="6")),
        "accused_district_code": _item(record, "accused_district_code", "dist_code_res_off", default=_s(show, "dist_code_res_off")),
        "accused_taluka_code": _item(record, "accused_taluka_code", "taluka_code_res_off", default=_s(show, "taluka_code_res_off")),
        "accused_advocate_type": _item(record, "accused_advocate_type", default="R"),
        "accused_advocate_name": _item(record, "accused_advocate_name", "respondent_advocate_name", "res_adv", default=_s(show, "res_adv")),
        "accused_advocate_barcode": _item(record, "accused_advocate_barcode", "resbar_code", default=_s(show, "resbar_code")),
        "accused_advocate_code": _item(record, "accused_advocate_code", "res_adv_cd", default=_s(show, "res_adv_cd", default="0")),

        "case_state_code": _item(record, "case_state_code", default=_s(show, "case_state_code", default="6")),
        "case_district_code": _item(record, "case_district_code", "case_dist_code", default=_s(show, "case_dist_code", default="1")),
        "case_taluka_code": _item(record, "case_taluka_code", default=_s(show, "case_taluka_code", default="2")),
        "police_private": _item(record, "police_private", default=_s(show, "police_private", default="2")),
        "police_state_code": _item(record, "police_state_code", default="6"),
        "police_district_code": _item(record, "police_district_code", default=_s(show, "case_dist_code", default="1")),
        "police_station_code": _item(record, "police_station_code", "police_st_code", default=_s(show, "police_st_code")),
        "fir_no": _item(record, "fir_no", default=_s(show, "fir_no")),
        "fir_year": _item(record, "fir_year", default=_s(show, "fir_year")),
        "fir_date": _item(record, "fir_date", default=_s(show, "fir_date")),
        "offense_date": _ddmmyyyy(_item(record, "offense_date", "dishonour_date", default=_s(show, "offense_date"))),
        "cause_of_action": _item(record, "cause_of_action", "causeofaction", default=_s(show, "causeofaction")),
        "local_cause_of_action": _item(record, "local_cause_of_action", "lcauseofaction", default=_s(show, "lcauseofaction", "causeofaction")),
        "relief": _item(record, "relief", "relief_offense", default=_s(show, "relief_offense")),
        "jurisdiction_value": _item(record, "jurisdiction_value", "juri_value", default=_s(show, "juri_value", "amount")),
        "amount": _item(record, "amount", "cheque_amount", default=_s(show, "amount")),
        "filing_date": _ddmmyyyy(_item(record, "filing_date", "date_of_filing", default=_s(show, "date_of_filing", default=reg_dt))),
        "filing_time": _item(record, "filing_time", "time_of_filing", default=_s(show, "time_of_filing")),
        "filing_type": _item(record, "filing_type", default="2"),
        "filing_type1": _item(record, "filing_type1", default="2"),
        "freg_no": _item(record, "freg_no", default="NaN"),
        "freg_no_comp": _item(record, "freg_no_comp", default="NaN"),
        "fitem_no": _item(record, "fitem_no", default=_s(show, "mvc_itemno_max", default="1")),
        "injury_type": _item(record, "injury_type", default="4"),
        "ftype": _item(record, "ftype", default="2"),
        "radiotype": _item(record, "radiotype", default="2"),
        "searchcaveat": _item(record, "searchcaveat", default="1"),
        "rcaveator": _item(record, "rcaveator", default="1"),
        "acts": record.get("acts") or [
            {
                "act_name": "Negotiable Instruments Act",
                "hidden_act_code": "18810260099001 ",
                "act_code": "732",
                "section_code": "138",
            }
        ],
        "_fetched": {
            "source": "registration.showdetails",
            "requires_user_review": True,
            "already_registered": _s(show, "already_registered"),
            "nosuch_filingno": _s(show, "nosuch_filingno"),
            "server_date": _s(show, "serverDate"),
            "showdetails_keys": sorted(show.keys()),
        },
    }
    return draft


def fetch_registration(session: CisSession, record: dict) -> dict:
    """Fetch registration read data and return a transformed draft record."""
    cnr, filing = _identifier(record)
    lookup = cnr or filing
    if not lookup:
        raise CisError("identifier_missing", "registration prefetch requires cis_cnr/cnr or filing_no")

    page = session.get("registration/registration.php", params={
        "linkid": _item(record, "registration_linkid", default=DEFAULT_REGISTRATION_LINKID),
        "mode": _item(record, "registration_mode", default=DEFAULT_REGISTRATION_MODE),
        "cino": lookup,
    })
    appellate_raw = session.post("registration/registrationajax.php", {"x": "appellateCourt"})
    appellate = parse_json_response(appellate_raw, allow_empty=True)
    mode_of_filing = _item(record, "mode_of_filing", default=_s(appellate, "mode_of_filing", default="2"))
    show_raw = session.post("registration/registrationajax.php", {
        "x": "showdetails",
        "filingno": lookup,
        "mode_of_filing": mode_of_filing,
    })
    show = parse_json_response(show_raw)
    if str(show.get("nosuch_filingno", "")).lower() == "yes":
        raise CisError("not_found", "registration showdetails returned nosuch_filingno=yes", show)
    draft = _registration_draft(record, show, appellate, session.config.login_date)
    return {
        "status": "prefetched",
        "cis_cnr": draft.get("cis_cnr") or lookup,
        "draft": draft,
        "fetched": {
            "page_form_fields": len(parse_form(page, "frm")),
            "showdetails": show,
            "appellateCourt": appellate,
        },
    }


def _tag_attr(tag: str, name: str) -> str:
    quoted = re.search(rf"\b{re.escape(name)}\s*=\s*(['\"])(.*?)\1", tag or "", re.I | re.S)
    if quoted:
        return html_lib.unescape(quoted.group(2))
    bare = re.search(rf"\b{re.escape(name)}\s*=\s*([^\s'\">]+)", tag or "", re.I | re.S)
    return html_lib.unescape(bare.group(1)) if bare else ""


def _clean_html_text(value: str) -> str:
    text = re.sub(r"<[^>]+>", " ", value or "")
    return re.sub(r"\s+", " ", html_lib.unescape(text)).strip()


def _option_items(select_html: str) -> list[dict[str, str]]:
    out: list[dict[str, str]] = []
    for match in re.finditer(r"<option\b([^>]*)>(.*?)</option>", select_html or "", re.I | re.S):
        tag = "<option " + match.group(1) + ">"
        value = _tag_attr(tag, "value")
        label = _clean_html_text(match.group(2))
        if value or label:
            out.append({"value": value, "label": label, "selected": "true" if re.search(r"\bselected\b", match.group(1), re.I) else "false"})
    return out


def _selected_option(select_html: str) -> tuple[str, str]:
    options = _option_items(select_html)
    for option in options:
        if option.get("selected") == "true":
            return option.get("value", ""), option.get("label", "")
    return "", ""


def _merge_options(*option_lists: list[dict[str, str]]) -> list[dict[str, str]]:
    merged: list[dict[str, str]] = []
    seen: set[str] = set()
    for options in option_lists:
        for option in options:
            value = str(option.get("value") or "")
            if not value or value in seen:
                continue
            seen.add(value)
            merged.append({"value": value, "label": str(option.get("label") or value)})
    return merged


def _parse_present_party_options(*html_parts: str) -> list[dict[str, str]]:
    from_options: list[dict[str, str]] = []
    from_checkboxes: list[dict[str, str]] = []
    for html in html_parts:
        if not html:
            continue
        from_options.extend(_option_items(html))
        rows = re.findall(r"<tr\b.*?</tr>", html, re.I | re.S) or [html]
        for row in rows:
            for match in re.finditer(r"<input\b[^>]*\bname\s*=\s*(['\"]?)present\[\]\1[^>]*>", row, re.I | re.S):
                tag = match.group(0)
                value = _tag_attr(tag, "value")
                if not value:
                    continue
                label = _clean_html_text(row)
                from_checkboxes.append({"value": value, "label": f"{label} ({value})" if label else value})
    return _merge_options(from_options, from_checkboxes)


def _row_segment(html: str, pos: int) -> str:
    start = html.rfind("<tr", 0, pos)
    end = html.find("</tr>", pos)
    if start < 0:
        start = max(0, pos - 1000)
    if end < 0:
        end = min(len(html), pos + 1000)
    else:
        end += len("</tr>")
    return html[start:end]


def _party_from_checkbox(segment: str, checkbox_name: str, idx: str) -> dict[str, str]:
    match = re.search(rf"<input\b[^>]*\bname\s*=\s*(['\"]?){re.escape(checkbox_name)}\[{re.escape(idx)}\]\1[^>]*>", segment, re.I | re.S)
    value = _tag_attr(match.group(0), "value") if match else ""
    parts = value.split("~")
    out = {"party_value": value}
    if len(parts) >= 4:
        out.update({"party_serial": parts[0], "party_name": parts[1], "party_no": parts[2], "role": parts[3]})
    return out


def _parse_appearance_rows(html: str) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    seen: set[str] = set()
    for match in re.finditer(r"<input\b[^>]*\bname\s*=\s*(['\"]?)appearance_party_no\[(\d+)\]\1[^>]*>", html or "", re.I | re.S):
        idx = match.group(2)
        if idx in seen:
            continue
        seen.add(idx)
        segment = _row_segment(html, match.start())
        process_select = re.search(rf"<select\b[^>]*\bname\s*=\s*(['\"]?)selProcessIss\[{re.escape(idx)}\]\1[^>]*>.*?</select>", segment, re.I | re.S)
        process_issue, process_label = _selected_option(process_select.group(0) if process_select else "")
        issue = re.search(rf"<input\b[^>]*\bname\s*=\s*(['\"]?)fissue_date\[{re.escape(idx)}\]\1[^>]*>", segment, re.I | re.S)
        adv = re.search(rf"<input\b[^>]*\bname\s*=\s*(['\"]?)fapp_madv_MP\[{re.escape(idx)}\]\1[^>]*>", segment, re.I | re.S)
        adv_code = re.search(rf"<input\b[^>]*\bname\s*=\s*(['\"]?)fapp_adv_cdMP\[{re.escape(idx)}\]\1[^>]*>", segment, re.I | re.S)
        row = {
            "row": idx,
            "appearance_party_no": _tag_attr(match.group(0), "value"),
            "process_issue": process_issue,
            "process_issue_label": process_label,
            "issue_date": _tag_attr(issue.group(0), "value") if issue else "",
            "advocate_name": _tag_attr(adv.group(0), "value") if adv else "",
            "advocate_code": _tag_attr(adv_code.group(0), "value") if adv_code else "0",
        }
        row.update(_party_from_checkbox(segment, "examinationappearance", idx))
        rows.append(row)
    return rows


def _parse_status313_rows(html: str) -> list[dict[str, str]]:
    by_idx: dict[str, dict[str, str]] = {}
    for match in re.finditer(r"<input\b[^>]*\bname\s*=\s*(['\"]?)status313\[(\d+)\]\1[^>]*>", html or "", re.I | re.S):
        idx = match.group(2)
        tag = match.group(0)
        row = by_idx.setdefault(idx, {"row": idx, "status_313": ""})
        if not row.get("status_313") or re.search(r"\bchecked\b", tag, re.I):
            row["status_313"] = _tag_attr(tag, "value") or "1"
        row.update(_party_from_checkbox(_row_segment(html, match.start()), "examination313", idx))
    return [by_idx[k] for k in sorted(by_idx, key=lambda x: int(x))]


def _parse_previous_delay_rows(html: str) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    for row in re.findall(r"<tr\b.*?</tr>", html or "", re.I | re.S):
        cells = [_clean_html_text(cell) for cell in re.findall(r"<td\b[^>]*>(.*?)</td>", row, re.I | re.S)]
        if len(cells) >= 2:
            rows.append({"serial": cells[0], "reason": cells[1], "since_date": cells[2] if len(cells) > 2 else ""})
    return rows


def _safe_post_json(session: CisSession, path: str, data: dict[str, Any]) -> dict:
    try:
        return parse_json_response(session.post(path, data, xhr=True), allow_empty=True)
    except CisError as exc:
        return {"_error": exc.to_dict()}


def _case_proceeding_draft(record: dict, fetch: dict, cnr: str, login_date: str, panels: dict[str, dict] | None = None) -> dict:
    panels = panels or {}
    proceeding_date = _ddmmyyyy(_item(record, "proceeding_date", "current_date", default=login_date or _today_ddmmyyyy()))
    current_purpose = _s(fetch, "purpose_next", "m_purpose_code")
    current_subpurpose = _s(fetch, "purpose_prev")
    next_purpose = _item(record, "next_listing_purpose_code", "purpose_code", "fpurpose_code")
    next_subpurpose = _item(record, "next_listing_subpurpose_code", "subpurpose_code", "fsubpurpose_code", default="")
    if not next_subpurpose or next_subpurpose == "0":
        next_subpurpose = ""
    counsel = record.get("counsel_present", ["MP"])
    if isinstance(counsel, str):
        counsel = [counsel] if counsel else []
    dispose_flag = _bool(record.get("dispose_flag", False)) or _item(record, "type") == "disposal"

    showparties_html = _s(panels.get("showparties", {}), "selectBox")
    fetchparty_html = _s(panels.get("fetchparty", {}), "party_table")
    appearance_rows = record.get("appearance_rows") if isinstance(record.get("appearance_rows"), list) else _parse_appearance_rows(_s(panels.get("fetchappearance", {}), "table_cases"))
    status313_rows = record.get("status313_rows") if isinstance(record.get("status313_rows"), list) else _parse_status313_rows(_s(panels.get("fetch313crpc", {}), "table_cases"))
    party_options = _parse_present_party_options(showparties_html, fetchparty_html)
    previous_delay_rows = _parse_previous_delay_rows(_s(panels.get("show_previous_delay", {}), "partyname"))
    panel_errors = {name: panel.get("_error") for name, panel in panels.items() if isinstance(panel, dict) and panel.get("_error")}

    draft = {
        "external_id": _external_id(record, cnr, prefix="PROC"),
        "court_no": _item(record, "court_no", "fcourt_no", "target_court_no", "allocated_court_no"),
        "cis_cnr": cnr,
        "type": "disposal" if dispose_flag else _item(record, "type", default="next_hearing"),
        "proceeding_date": proceeding_date,
        "next_listing_purpose_code": str(next_purpose),
        "next_listing_subpurpose_code": str(next_subpurpose),
        "next_hearing_date": "" if dispose_flag else _ddmmyyyy(_item(record, "next_hearing_date", "next_date", "fnext_date", default=_s(fetch, "m_next_date"))),
        "business_remarks": _item(record, "business_remarks", "fbusiness"),
        "dormant_flag": _item(record, "dormant_flag", "fdormant", default="D" if dispose_flag else "S"),
        "case_type_flag": _item(record, "case_type_flag", "civ_cri", default="3"),
        "case_type_code": _item(record, "case_type_code", "fmm_case_type", default=_s(fetch, "filcase_type", "case_type", default="55")),
        "counsel_present": counsel,
        "dispose_flag": dispose_flag,
        "decision_date": _ddmmyyyy(_item(record, "decision_date", "fdt_decision")),
        "disposal_radio_type": _item(record, "disposal_radio_type", "radio_disp_type", default="2" if dispose_flag else ""),
        "disposal_type": _item(record, "disposal_type", "fdisp_type"),
        "dor_sinedie": _bool(record.get("dor_sinedie", False)),
        "through_vc": _bool(record.get("through_vc", record.get("thro_vc", False))),
        "_fetched": {
            "source": "case_proceeding.fetchdata+dependent_panels" if panels else "case_proceeding.fetchdata",
            "requires_user_review": True,
            "case_number": _s(fetch, "case_no"),
            "filing_number": _s(fetch, "filing_no"),
            "petitioner_name": _s(fetch, "eng_pet_name", "pet_name"),
            "respondent_name": _s(fetch, "eng_res_name", "res_name"),
            "current_listing_purpose_code": current_purpose,
            "current_listing_purpose_name": _s(fetch, "purpose_name"),
            "current_listing_subpurpose_code": current_subpurpose,
            "date_of_filing": _s(fetch, "date_of_filing"),
            "registration_date": _s(fetch, "dt_regis"),
            "pending_ia": _s(fetch, "pending_ia"),
            "display_delay_reason_flag": _s(fetch, "displayDelayReasonFlag"),
            "delay_count": _s(fetch, "delayCnt"),
            "purpose_flag": _s(fetch, "purpose_flag"),
        },
    }
    if party_options:
        draft["party_presence_options"] = party_options
    if appearance_rows:
        draft["appearance_rows"] = appearance_rows
    if status313_rows:
        draft["status313_rows"] = status313_rows
    if previous_delay_rows:
        draft["_fetched"]["previous_delay_reasons"] = previous_delay_rows
    if panel_errors:
        draft["_fetched"]["dependent_panel_errors"] = panel_errors
    return draft


def fetch_case_proceeding(session: CisSession, record: dict) -> dict:
    """Fetch case-proceeding read data and return a transformed draft record."""
    cnr, _ = _identifier(record)
    if not cnr:
        raise CisError("identifier_missing", "case_proceeding prefetch requires cis_cnr/cnr")
    page = session.get("proceedings/case_proceeding.php", params={
        "linkid": _item(record, "case_proceeding_linkid", default=DEFAULT_CASE_PROCEEDING_LINKID),
        "mode": _item(record, "case_proceeding_mode", default=DEFAULT_CASE_PROCEEDING_MODE),
    })
    base_items = parse_form(page, "frm")
    base = dict(base_items)
    case_type = _item(record, "case_type_code", "fmm_case_type", default="55")
    case_radio = _item(record, "case_type_flag", "civ_cri", default="3")
    base.update({
        "case_radio": case_radio,
        "fcase_no": f"{case_type}~{cnr}~P",
        "fcino": cnr,
        "x": "fetchdata",
        "cino": cnr,
    })
    raw = session.post("proceedings/case_proceedingajax.php", base, xhr=True)
    fetch = parse_json_response(raw)
    if fetch.get("errcnr"):
        raise CisError("not_found", "case proceeding fetchdata returned errcnr", fetch.get("errcnr"))

    fcase_no = f"{case_type}~{cnr}~P"
    panel_case = {"cino": cnr, "case_type": case_type}
    panels: dict[str, dict] = {
        "fetchconvicted": _safe_post_json(session, "proceedings/case_proceedingajax.php", {"x": "fetchconvicted", **panel_case}),
        "partyselectbox": _safe_post_json(session, "proceedings/case_proceedingajax.php", {"x": "partyselectbox", "fcase_no": fcase_no}),
        "fetch_witness": _safe_post_json(session, "proceedings/case_proceedingajax.php", {"x": "fetch_witness", **panel_case}),
        "fetch313crpc": _safe_post_json(session, "proceedings/case_proceedingajax.php", {"x": "fetch313crpc", **panel_case}),
        "fetchappearance": _safe_post_json(session, "proceedings/case_proceedingajax.php", {"x": "fetchappearance", **panel_case}),
        "fetchwrittenstatus": _safe_post_json(session, "proceedings/case_proceedingajax.php", {"x": "fetchwrittenstatus", **panel_case}),
        "showparties": _safe_post_json(session, "proceedings/case_proceedingajax.php", {"x": "showparties", "cino": cnr}),
        "fetch_parties_for_undertrial": _safe_post_json(session, "proceedings/case_proceedingajax.php", {"x": "fetch_parties_for_undertrial", "cino": cnr}),
        "showreservedate": _safe_post_json(session, "proceedings/case_proceedingajax.php", {"x": "showreservedate", "cino": cnr}),
        "fetchparty": _safe_post_json(session, "proceedings/case_proceedingajax.php", {"x": "fetchparty", "cino": cnr, "civ_cri": case_radio, "casetype": case_type}),
    }
    delay_base = dict(base)
    delay_base.update({
        "x": "show_previous_delay",
        "case_no": _s(fetch, "case_no"),
        "fcino": cnr,
        "case_radio": case_radio,
        "fcase_no": fcase_no,
        "fpurpose_code": _s(fetch, "purpose_next", "m_purpose_code"),
        "fsubpurpose_code": "",
        "cino": "",
    })
    panels["show_previous_delay"] = _safe_post_json(session, "proceedings/case_proceedingajax.php", delay_base)

    draft = _case_proceeding_draft(record, fetch, cnr, session.config.login_date, panels)
    return {
        "status": "prefetched",
        "cis_cnr": cnr,
        "draft": draft,
        "fetched": {
            "page_form_fields": len(base_items),
            "fetchdata": fetch,
            "dependent_panels": panels,
        },
    }


__all__ = ["fetch_registration", "fetch_case_proceeding"]
