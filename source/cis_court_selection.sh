#!/usr/bin/env bash
# Reusable CIS court-selection helper.
# Source this from a CIS bridge after BASE and COOKIE have been initialised.

cis_truthy() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

# Usage:
#   cis_select_court_if_enabled "$BASE" "$COOKIE" "$COURT_NO" "$SKIP_COURT_SELECTION" "$STAGE_NAME" [radio_flag]
#
# Returns 0 when court selection succeeds or is skipped by flag.
# Returns non-zero when selection is enabled but court_no is missing or CIS call fails.
# Sets globals:
#   CIS_COURT_SELECTION_STATUS=success|skipped|failed
#   CIS_COURT_SELECTION_COURT_NO=<court_no>
cis_select_court_if_enabled() {
  local base="$1" cookie="$2" court_no="${3:-}" skip_flag="${4:-false}" stage="${5:-cis}" radio_flag="${6:-active}"
  local linkid="${SELECT_COURT_LINKID:-182}"
  local difflinkid="${SELECT_COURT_DIFFLINKID:-182}"
  local mode="${SELECT_COURT_MODE:-0}"
  local tmp_base="${TMPDIR:-/tmp}"
  local page="$tmp_base/select_court_${stage}_page.html"
  local fetch_before="$tmp_base/select_court_${stage}_fetch_before.json"
  local submit_resp="$tmp_base/select_court_${stage}_submit.json"
  local fetch_after="$tmp_base/select_court_${stage}_fetch_after.json"

  CIS_COURT_SELECTION_COURT_NO="$court_no"

  if cis_truthy "$skip_flag"; then
    CIS_COURT_SELECTION_STATUS="skipped"
    echo "[$stage] Court selection skipped by config; court_no=${court_no:-<empty>}" >&2
    return 0
  fi

  if [[ -z "$court_no" ]]; then
    CIS_COURT_SELECTION_STATUS="failed"
    echo "[$stage] ERROR: court_no missing and court selection is enabled" >&2
    return 1
  fi

  echo "[$stage] Selecting court $court_no..." >&2

  if ! curl -sS -b "$cookie" -c "$cookie" \
      "$base/proceedings/select_court.php?linkid=$linkid&difflinkid=$difflinkid&mode=$mode" > "$page"; then
    CIS_COURT_SELECTION_STATUS="failed"
    echo "[$stage] ERROR: failed to load select_court.php for court_no=$court_no" >&2
    return 1
  fi

  if ! curl -sS -b "$cookie" -c "$cookie" -X POST "$base/proceedings/select_courtajax.php" \
      -H "X-Requested-With: XMLHttpRequest" \
      --data-urlencode "x=fetch_bench" --data-urlencode "radio_flag=$radio_flag" > "$fetch_before"; then
    CIS_COURT_SELECTION_STATUS="failed"
    echo "[$stage] ERROR: failed to fetch bench before court selection; court_no=$court_no" >&2
    return 1
  fi

  if ! curl -sS -b "$cookie" -c "$cookie" -X POST "$base/proceedings/select_courtajax.php" \
      -H "X-Requested-With: XMLHttpRequest" \
      --data-urlencode "formaction=1" --data-urlencode "count1=" --data-urlencode "checkorder=" \
      --data-urlencode "fno_judges=" --data-urlencode "fcourt_no=$court_no" > "$submit_resp"; then
    CIS_COURT_SELECTION_STATUS="failed"
    echo "[$stage] ERROR: select_courtajax submit failed for court_no=$court_no" >&2
    return 1
  fi

  curl -sS -b "$cookie" -c "$cookie" -X POST "$base/proceedings/select_courtajax.php" \
    -H "X-Requested-With: XMLHttpRequest" \
    --data-urlencode "x=fetch_bench" --data-urlencode "radio_flag=$radio_flag" > "$fetch_after" 2>/dev/null || true

  if grep -Eiq 'syntax error|error|failed' "$submit_resp"; then
    CIS_COURT_SELECTION_STATUS="failed"
    echo "[$stage] ERROR: court selection failed for court_no=$court_no" >&2
    return 1
  fi

  CIS_COURT_SELECTION_STATUS="success"
  echo "[$stage] Court $court_no selected successfully" >&2
  return 0
}
