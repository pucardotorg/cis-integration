#!/usr/bin/env python3
"""Reusable read-oriented CIS session helpers for uploader/V3.

This module centralizes the duplicated login/unlock/logout, form parsing, and
noisy JSON parsing used by read-only prefetch tools.  It intentionally exposes
only generic GET/POST primitives; stage fetchers decide which read endpoints are
safe to call.
"""
from __future__ import annotations

import datetime as dt
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from html.parser import HTMLParser
from http.cookiejar import MozillaCookieJar
from pathlib import Path
from typing import Iterable, Mapping, Sequence


class CisError(RuntimeError):
    """Structured error for CIS fetch failures."""

    def __init__(self, code: str, message: str, detail: object | None = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.detail = detail

    def to_dict(self) -> dict:
        out = {"code": self.code, "message": self.message}
        if self.detail is not None:
            out["detail"] = self.detail
        return out


@dataclass
class CisConfig:
    base_url: str
    court_code: str
    user: str
    password: str
    unlock_password: str
    login_date: str
    lang_id: str = "0"
    cloud_flag: str = "N"
    court_no: str = ""
    skip_court_selection: str = "false"


def _today_ddmmyyyy() -> str:
    return dt.date.today().strftime("%d-%m-%Y")


def load_config(root: str | os.PathLike[str] | None = None) -> CisConfig:
    """Load config from env first, then Data/config.json, matching load_config.sh."""
    root_path = Path(root or Path(__file__).resolve().parents[1])
    data: dict = {}
    cfg = root_path / "Data" / "config.json"
    if cfg.exists():
        data = json.load(open(cfg, encoding="utf-8"))

    def get(key: str, default: str = "") -> str:
        value = os.environ.get(key)
        if value is None or value == "":
            value = data.get(key, default)
        return "" if value is None else str(value)

    password = get("CIS_PASSWORD")
    unlock = get("UNLOCK_PASSWORD") or password
    login_date = get("LOGIN_DATE") or _today_ddmmyyyy()
    return CisConfig(
        base_url=(get("CIS_BASE_URL") or "http://127.0.0.1/swecourtis").rstrip("/"),
        court_code=get("COURT_CODE") or "HRPK02",
        user=get("CIS_USER") or "supuser",
        password=password or "ecourt123",
        unlock_password=unlock or password or "ecourt123",
        login_date=login_date,
        lang_id=get("LANG_ID") or "0",
        cloud_flag=get("CLOUD_FLAG") or "N",
        court_no=get("COURT_NO"),
        skip_court_selection=get("SKIP_COURT_SELECTION") or "false",
    )


class _FormParser(HTMLParser):
    def __init__(self, form_id: str = "frm"):
        super().__init__()
        self.form_id = form_id
        self.in_form = False
        self.in_textarea: str | None = None
        self.textarea_value = ""
        self.items: list[tuple[str, str]] = []
        self.select_name: str | None = None
        self.select_value = ""

    def handle_starttag(self, tag: str, attrs: Sequence[tuple[str, str | None]]):
        attrs_d = {k: ("" if v is None else v) for k, v in attrs}
        if tag == "form" and attrs_d.get("id") == self.form_id:
            self.in_form = True
        if not self.in_form:
            return
        if tag == "input":
            name = attrs_d.get("name")
            if not name:
                return
            typ = (attrs_d.get("type") or "").lower()
            if typ in ("button", "submit", "reset", "file", "image"):
                return
            if typ in ("radio", "checkbox") and "checked" not in attrs_d:
                return
            self.items.append((name, attrs_d.get("value", "")))
        elif tag == "select":
            self.select_name = attrs_d.get("name")
            self.select_value = ""
        elif tag == "option" and self.select_name and "selected" in attrs_d:
            self.select_value = attrs_d.get("value", "")
        elif tag == "textarea":
            self.in_textarea = attrs_d.get("name")
            self.textarea_value = ""

    def handle_data(self, data: str):
        if self.in_textarea:
            self.textarea_value += data

    def handle_endtag(self, tag: str):
        if tag == "select" and self.select_name:
            self.items.append((self.select_name, self.select_value))
            self.select_name = None
            self.select_value = ""
        elif tag == "textarea" and self.in_textarea:
            self.items.append((self.in_textarea, self.textarea_value))
            self.in_textarea = None
            self.textarea_value = ""
        elif tag == "form" and self.in_form:
            self.in_form = False


def parse_form(html: str, form_id: str = "frm") -> list[tuple[str, str]]:
    parser = _FormParser(form_id=form_id)
    parser.feed(html or "")
    return parser.items


def parse_json_response(raw: str, *, allow_empty: bool = False) -> dict:
    """Parse JSON object from CIS responses that may contain surrounding noise."""
    raw = raw or ""
    match = re.search(r"\{.*\}", raw, re.S)
    if not match:
        if allow_empty:
            return {}
        raise CisError("parse_failed", "CIS response did not contain a JSON object", raw[:500])
    try:
        value = json.loads(match.group(0))
    except Exception as exc:  # pragma: no cover - message matters more than type
        raise CisError("parse_failed", f"CIS JSON parse failed: {exc}", raw[:500]) from exc
    if not isinstance(value, dict):
        raise CisError("parse_failed", "CIS JSON response was not an object", value)
    return value


def urlencode_pairs(data: Mapping[str, object] | Iterable[tuple[str, object]]) -> bytes:
    return urllib.parse.urlencode(data, doseq=True).encode("utf-8")


def _truthy(value: object) -> bool:
    return str(value or "").strip().lower() in {"1", "true", "yes", "y", "on"}


class CisSession:
    def __init__(self, config: CisConfig, cookie_path: str | os.PathLike[str] | None = None, timeout: int = 60):
        self.config = config
        self.timeout = timeout
        self.cookie_path = str(cookie_path or "")
        self.cookie_jar = MozillaCookieJar(self.cookie_path) if self.cookie_path else MozillaCookieJar()
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.cookie_jar))
        self.logged_in = False

    @property
    def base_url(self) -> str:
        return self.config.base_url.rstrip("/")

    def _url(self, path: str, params: Mapping[str, object] | None = None) -> str:
        if path.startswith("http://") or path.startswith("https://"):
            url = path
        else:
            url = f"{self.base_url}/{path.lstrip('/')}"
        if params:
            sep = "&" if "?" in url else "?"
            url += sep + urllib.parse.urlencode(params, doseq=True)
        return url

    def request(self, method: str, path: str, data: Mapping[str, object] | Iterable[tuple[str, object]] | bytes | str | None = None, *, headers: Mapping[str, str] | None = None, params: Mapping[str, object] | None = None) -> str:
        body: bytes | None
        req_headers = {
            "User-Agent": "Mozilla/5.0 CIS-prefetch/uploader-v3",
            "Accept": "*/*",
        }
        if headers:
            req_headers.update(headers)
        if data is None:
            body = None
        elif isinstance(data, bytes):
            body = data
        elif isinstance(data, str):
            body = data.encode("utf-8")
        else:
            body = urlencode_pairs(data)
            req_headers.setdefault("Content-Type", "application/x-www-form-urlencoded")
        req = urllib.request.Request(self._url(path, params=params), data=body, method=method.upper(), headers=req_headers)
        try:
            with self.opener.open(req, timeout=self.timeout) as resp:
                return resp.read().decode("utf-8", errors="ignore")
        except urllib.error.HTTPError as exc:
            raw = exc.read().decode("utf-8", errors="ignore")
            raise CisError("http_error", f"HTTP {exc.code} calling {path}", raw[:1000]) from exc
        except urllib.error.URLError as exc:
            raise CisError("network_error", f"Network error calling {path}: {exc}") from exc

    def get(self, path: str, params: Mapping[str, object] | None = None, *, headers: Mapping[str, str] | None = None) -> str:
        return self.request("GET", path, params=params, headers=headers)

    def post(self, path: str, data: Mapping[str, object] | Iterable[tuple[str, object]] | bytes | str | None = None, *, xhr: bool = False, headers: Mapping[str, str] | None = None) -> str:
        h = dict(headers or {})
        if xhr:
            h.setdefault("X-Requested-With", "XMLHttpRequest")
        return self.request("POST", path, data=data, headers=h)

    def encrypt_password(self, password: str) -> str:
        try:
            proc = subprocess.run(
                ["openssl", "enc", "-aes-256-cbc", "-salt", "-md", "md5", "-a", "-A", "-pass", "pass:myPassword"],
                input=password.encode("utf-8"),
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                check=True,
            )
        except FileNotFoundError as exc:
            raise CisError("missing_tool", "Missing command: openssl") from exc
        except subprocess.CalledProcessError as exc:
            raise CisError("openssl_failed", "Password encryption failed") from exc
        return proc.stdout.decode("utf-8", errors="ignore").strip()

    def _loginuser(self, encrypted_password: str) -> str:
        raw = self.post("loginajax1.php", {
            "databasetype": self.config.court_code,
            "username": self.config.user,
            "pass_word": encrypted_password,
            "logindate": self.config.login_date,
            "lang_id": self.config.lang_id,
            "hidd_otp": "",
            "x": "loginuser",
            "cloud_flag": self.config.cloud_flag,
        })
        parsed = parse_json_response(raw)
        return str(parsed.get("output", ""))

    def unlock_user(self) -> None:
        html = self.get("index_unlock.php")
        items = [(k, v) for k, v in parse_form(html, "frm_unlock") if k not in {"unlock_username", "unlock_pass_word", "unlock_confirmpass_word"}]
        enc = self.encrypt_password(self.config.unlock_password)
        items.extend([
            ("unlock_username", self.config.user),
            ("unlock_pass_word", enc),
            ("unlock_confirmpass_word", enc),
            ("x", "checkunlock_fromindex"),
        ])
        raw = self.post("loginajax1.php", items)
        parsed = parse_json_response(raw)
        if parsed.get("msgnn") != "Unlocked Successfully":
            raise CisError("unlock_failed", "CIS unlock failed", parsed)

    def login(self) -> None:
        enc = self.encrypt_password(self.config.password)
        self.get("")
        self.post("loginajax1.php", {"x": "fetchdata", "est_code": self.config.court_code})
        out = self._loginuser(enc)
        if out == "UserLogged":
            print("CIS: user already logged in. Attempting unlock...", file=sys.stderr)
            self.unlock_user()
            out = self._loginuser(enc)
        if out != "yes":
            raise CisError("login_failed", f"CIS login failed: output={out}")
        sessstore = str(int(time.time()))
        self.post(f"o_index1.php?sessstore={sessstore}", {
            "databasetype": self.config.court_code,
            "username": self.config.user,
            "pass_word": enc,
            "logindate": self.config.login_date,
            "lang_id": self.config.lang_id,
            "hidd_otp": "",
        })
        self.logged_in = True

    def select_court_if_enabled(self, *, court_no: str | None = None, skip: object | None = None, stage: str = "cis", radio_flag: str = "active") -> dict:
        """Select the active proceedings court in the current CIS session.

        Mirrors source/cis_court_selection.sh so Python prefetch flows do not
        depend on whatever court happened to be active from an earlier session.
        """
        selected_court = str(court_no if court_no is not None else self.config.court_no or "")
        skip_flag = self.config.skip_court_selection if skip is None else skip
        if _truthy(skip_flag):
            return {"status": "skipped", "court_no": selected_court, "stage": stage}
        if not selected_court:
            raise CisError("court_selection_missing", f"court_no missing and court selection is enabled for {stage}")

        linkid = os.environ.get("SELECT_COURT_LINKID") or "182"
        difflinkid = os.environ.get("SELECT_COURT_DIFFLINKID") or "182"
        mode = os.environ.get("SELECT_COURT_MODE") or "0"
        self.get("proceedings/select_court.php", params={"linkid": linkid, "difflinkid": difflinkid, "mode": mode})
        self.post("proceedings/select_courtajax.php", {"x": "fetch_bench", "radio_flag": radio_flag}, xhr=True)
        submit = self.post("proceedings/select_courtajax.php", {
            "formaction": "1",
            "count1": "",
            "checkorder": "",
            "fno_judges": "",
            "fcourt_no": selected_court,
        }, xhr=True)
        try:
            self.post("proceedings/select_courtajax.php", {"x": "fetch_bench", "radio_flag": radio_flag}, xhr=True)
        except Exception:
            pass
        if re.search(r"syntax error|error|failed", submit or "", re.I):
            raise CisError("court_selection_failed", f"court selection failed for court_no={selected_court}", submit[:1000])
        return {"status": "success", "court_no": selected_court, "stage": stage}

    def logout(self) -> None:
        if not self.logged_in:
            return
        try:
            self.get("logout.php")
        except Exception:
            pass
        self.logged_in = False


__all__ = [
    "CisConfig",
    "CisError",
    "CisSession",
    "load_config",
    "parse_form",
    "parse_json_response",
    "urlencode_pairs",
]
