#!/usr/bin/env bash
set -euo pipefail

# codex-accounts.sh — manage multiple Codex CLI accounts
# Storage layout:
#   Auths:  ~/codex-data/<account>.auth.json
#   State:  ~/.codex-switch/state   (CURRENT=..., PREVIOUS=...)

CODENAME="codex"
CODEX_HOME="${HOME}/.codex"
AUTH_FILE="${CODEX_HOME}/auth.json"
DATA_DIR="${HOME}/codex-data"
STATE_DIR="${HOME}/.codex-switch"
STATE_FILE="${STATE_DIR}/state"

# Auto-switch heuristic tuning.
# - Exclude accounts with 5h remaining <= this threshold (unusable right now).
AUTO_SWITCH_FIVEH_UNUSABLE_PCT="${CODEX_ACCOUNTS_FIVEH_UNUSABLE_PCT:-5}"
# If reset_at is missing, treat it as "very far in the future" for scoring.
AUTO_SWITCH_UNKNOWN_RESET_TTR_SEC="${CODEX_ACCOUNTS_UNKNOWN_RESET_TTR_SEC:-315360000}" # 10 years

# Usage fetching performance tuning.
USAGE_FETCH_CONCURRENCY="${CODEX_ACCOUNTS_USAGE_CONCURRENCY:-6}"
USAGE_CACHE_TTL_SEC="${CODEX_ACCOUNTS_USAGE_CACHE_TTL_SEC:-20}"
USAGE_CACHE_FILE="${STATE_DIR}/usage-cache.json"

# ------------- utils -------------
die() { echo "[ERR] $*" >&2; exit 1; }
note() { echo "[*] $*"; }
ok()  { echo "[OK] $*"; }

require_bin() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' not found. Install it first."
}

ensure_dirs() {
  mkdir -p "$DATA_DIR" "$STATE_DIR"
}

load_state() {
  CURRENT=""; PREVIOUS=""
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE" || true
  fi
}

save_state() {
  local cur="$1" prev="$2"
  printf "CURRENT=%q\nPREVIOUS=%q\n" "$cur" "$prev" > "$STATE_FILE"
}

auth_path_for() {
  local name="$1"
  echo "${DATA_DIR}/${name}.auth.json"
}

auth_identity_for_file() {
  # Prints a stable identity string for a ChatGPT login (account_id/user_id) if available.
  # Returns empty if identity can't be determined (e.g. API-key-only auth).
  local auth_file="$1"
  if ! command -v python3 >/dev/null 2>&1; then
    return 0
  fi

  python3 - "$auth_file" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(0)

tokens = data.get("tokens") or {}
account_id = tokens.get("account_id") or ""
user_id = tokens.get("user_id") or ""

if account_id:
    print(f"account_id:{account_id}")
elif user_id:
    print(f"user_id:{user_id}")
else:
    # API-key-only auth (or unknown format) -> no stable identity.
    sys.exit(0)
PY
}

match_saved_account_by_identity() {
  local identity="$1"
  [[ -z "$identity" ]] && return 1
  shopt -s nullglob
  for f in "$DATA_DIR"/*.auth.json; do
    local other_id
    other_id="$(auth_identity_for_file "$f")"
    if [[ -n "$other_id" && "$other_id" == "$identity" ]]; then
      local name; name="$(basename "${f%%.auth.json}" .auth.json)"
      echo "$name"
      return 0
    fi
  done
  return 1
}

assert_codex_present_or_hint() {
  if [[ ! -d "$CODEX_HOME" ]]; then
    die "~/.codex not found. You likely haven't logged in yet.
Install Codex:  brew install codex
Then run:       ${CODENAME} login"
  fi
}

assert_auth_present_or_hint() {
  assert_codex_present_or_hint
  if [[ ! -f "$AUTH_FILE" ]]; then
    die "~/.codex/auth.json not found. You likely haven't logged in yet.
Then run:       ${CODENAME} login"
  fi
}

usage_status_lines_for_auth() {
  # Best-effort: fetch usage directly from the Codex backend (/usage).
  local auth_file="$1"
  if ! command -v python3 >/dev/null 2>&1; then
    note "python3 not found; skipping usage." >&2
    return 0
  fi

  local output=""
  output="$(
    python3 - "$auth_file" "$CODEX_HOME/config.toml" <<'PY'
import datetime as dt
import json
import os
import re
import sys
import urllib.error
import urllib.request

def warn(msg: str) -> None:
    sys.stderr.write(f"[*] {msg}\n")

auth_file = sys.argv[1]
config_file = sys.argv[2]

try:
    with open(auth_file, "r", encoding="utf-8") as f:
        auth = json.load(f)
except FileNotFoundError:
    warn("~/.codex/auth.json not found; skipping usage.")
    sys.exit(0)
except Exception as e:
    warn(f"Unable to read auth.json: {e}")
    sys.exit(0)

tokens = auth.get("tokens") or {}
access_token = tokens.get("access_token") or ""
account_id = tokens.get("account_id") or ""

if not access_token:
    if auth.get("OPENAI_API_KEY"):
        warn("Usage is only available for ChatGPT login tokens; skipping.")
    else:
        warn("No ChatGPT access token found in auth.json; skipping usage.")
    sys.exit(0)

base_url = "https://chatgpt.com/backend-api"
if os.path.exists(config_file):
    try:
        with open(config_file, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                m = re.match(r"chatgpt_base_url\s*=\s*(['\"])(.*?)\1", line)
                if m:
                    base_url = m.group(2)
                    break
    except Exception:
        pass

base_url = base_url.rstrip("/")
if (base_url.startswith("https://chatgpt.com") or base_url.startswith("https://chat.openai.com")) and "/backend-api" not in base_url:
    base_url = f"{base_url}/backend-api"

path = "/wham/usage" if "/backend-api" in base_url else "/api/codex/usage"
url = f"{base_url}{path}"

headers = {
    "Authorization": f"Bearer {access_token}",
    "User-Agent": "codex-cli",
}
if account_id:
    headers["ChatGPT-Account-Id"] = account_id

req = urllib.request.Request(url, headers=headers)
try:
    with urllib.request.urlopen(req, timeout=10) as resp:
        body = resp.read().decode("utf-8")
except urllib.error.HTTPError as e:
    warn(f"Usage request failed: HTTP {e.code}")
    sys.exit(0)
except Exception as e:
    warn(f"Usage request failed: {e}")
    sys.exit(0)

try:
    payload = json.loads(body)
except Exception as e:
    warn(f"Unable to parse usage response: {e}")
    sys.exit(0)

rate_limit = payload.get("rate_limit") or {}

def label_for_seconds(seconds, fallback):
    if not seconds:
        return fallback
    minutes = max(0, int(seconds // 60))
    minutes_per_hour = 60
    minutes_per_day = 24 * minutes_per_hour
    minutes_per_week = 7 * minutes_per_day
    minutes_per_month = 30 * minutes_per_day
    rounding_bias = 3

    if minutes <= minutes_per_day + rounding_bias:
        hours = max(1, (minutes + rounding_bias) // minutes_per_hour)
        return f"{hours}h"
    if minutes <= minutes_per_week + rounding_bias:
        return "weekly"
    if minutes <= minutes_per_month + rounding_bias:
        return "monthly"
    return "annual"

def pretty_label(label):
    if not label:
        return label
    return label[0].upper() + label[1:] if label[0].isalpha() else label

def format_reset(reset_at):
    if reset_at is None:
        return None
    try:
        dt_reset = dt.datetime.fromtimestamp(int(reset_at), tz=dt.timezone.utc).astimezone()
    except Exception:
        return None
    now = dt.datetime.now().astimezone()
    time = dt_reset.strftime("%H:%M")
    if dt_reset.date() == now.date():
        return time
    day = dt_reset.strftime("%d").lstrip("0")
    month = dt_reset.strftime("%b")
    return f"{time} on {day} {month}"

def format_window(window, fallback_label):
    if not isinstance(window, dict):
        return None
    used = window.get("used_percent")
    if used is None:
        return None
    label = pretty_label(label_for_seconds(window.get("limit_window_seconds"), fallback_label))
    reset = format_reset(window.get("reset_at"))
    if reset:
        return f"{label} limit: {used}% used (resets {reset})"
    return f"{label} limit: {used}% used"

lines = []
primary = format_window(rate_limit.get("primary_window"), "5h")
secondary = format_window(rate_limit.get("secondary_window"), "weekly")
if primary:
    lines.append(primary)
if secondary:
    lines.append(secondary)

if lines:
    print("\n".join(lines))
PY
  )"

  if [[ -z "${output//[[:space:]]/}" ]]; then
    return 0
  fi
  printf '%s\n' "$output" | sed '/^$/d'
}

usage_bulk_tool() {
  # Bulk usage fetch with parallelism + short-lived caching.
  # Modes:
  #   - best: prints the selected account name (for auto-pick)
  #   - status_blocks: prints blocks:
  #       @@ <name>
  #       <line>
  #       <line>
  local mode="$1"; shift
  if ! command -v python3 >/dev/null 2>&1; then
    return 0
  fi

  mkdir -p "$STATE_DIR"

  python3 - "$mode" "$USAGE_CACHE_FILE" "$CODEX_HOME/config.toml" \
    "$USAGE_CACHE_TTL_SEC" "$USAGE_FETCH_CONCURRENCY" \
    "$AUTO_SWITCH_FIVEH_UNUSABLE_PCT" "$AUTO_SWITCH_UNKNOWN_RESET_TTR_SEC" \
    "$@" <<'PY'
import concurrent.futures
import datetime as dt
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

mode = sys.argv[1]
cache_file = sys.argv[2]
config_file = sys.argv[3]
cache_ttl_sec = int(sys.argv[4])
concurrency = max(1, int(sys.argv[5]))
fiveh_unusable = int(sys.argv[6])
unknown_reset_ttr_sec = int(sys.argv[7])
auth_files = sys.argv[8:]

def name_for(path: str) -> str:
    base = os.path.basename(path)
    return base[:-len(".auth.json")] if base.endswith(".auth.json") else os.path.splitext(base)[0]

def load_base_url() -> str:
    base_url = "https://chatgpt.com/backend-api"
    if os.path.exists(config_file):
        try:
            with open(config_file, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#"):
                        continue
                    m = re.match(r"chatgpt_base_url\s*=\s*(['\"])(.*?)\1", line)
                    if m:
                        base_url = m.group(2)
                        break
        except Exception:
            pass
    base_url = base_url.rstrip("/")
    if (base_url.startswith("https://chatgpt.com") or base_url.startswith("https://chat.openai.com")) and "/backend-api" not in base_url:
        base_url = f"{base_url}/backend-api"
    return base_url

base_url = load_base_url()
path = "/wham/usage" if "/backend-api" in base_url else "/api/codex/usage"
url = f"{base_url}{path}"

def remaining_percent(used) -> int | None:
    if used is None:
        return None
    try:
        remaining = 100.0 - float(used)
    except Exception:
        return None
    if remaining < 0:
        remaining = 0.0
    if remaining > 100:
        remaining = 100.0
    return int(round(remaining))

def window_info(window):
    if not isinstance(window, dict):
        return {"used_percent": None, "reset_at": 0, "limit_window_seconds": None}
    used = window.get("used_percent")
    reset_at = window.get("reset_at")
    try:
        reset_at_i = int(reset_at) if reset_at is not None else 0
    except Exception:
        reset_at_i = 0
    return {
        "used_percent": used,
        "reset_at": reset_at_i,
        "limit_window_seconds": window.get("limit_window_seconds"),
    }

def fetch_one(auth_file: str) -> dict:
    try:
        with open(auth_file, "r", encoding="utf-8") as f:
            auth = json.load(f)
    except Exception:
        return {"ok": False, "reason": "read_failed"}

    tokens = auth.get("tokens") or {}
    access_token = tokens.get("access_token") or ""
    account_id = tokens.get("account_id") or ""
    if not access_token:
        return {"ok": False, "reason": "no_access_token"}

    headers = {"Authorization": f"Bearer {access_token}", "User-Agent": "codex-cli"}
    if account_id:
        headers["ChatGPT-Account-Id"] = account_id

    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            body = resp.read().decode("utf-8")
    except Exception:
        return {"ok": False, "reason": "http_failed"}

    try:
        payload = json.loads(body)
    except Exception:
        return {"ok": False, "reason": "parse_failed"}

    rate_limit = payload.get("rate_limit") or {}
    primary = window_info(rate_limit.get("primary_window"))
    secondary = window_info(rate_limit.get("secondary_window"))

    fiveh_remaining = remaining_percent(primary.get("used_percent"))
    weekly_remaining = remaining_percent(secondary.get("used_percent"))
    fiveh_remaining = fiveh_remaining if fiveh_remaining is not None else -1
    weekly_remaining = weekly_remaining if weekly_remaining is not None else -1

    return {
        "ok": True,
        "primary": primary,
        "secondary": secondary,
        "fiveh_remaining": fiveh_remaining,
        "weekly_remaining": weekly_remaining,
    }

results_by_path = {}
use_cache = False
if cache_ttl_sec > 0 and os.path.exists(cache_file):
    try:
        with open(cache_file, "r", encoding="utf-8") as f:
            cached = json.load(f)
        fetched_at = float(cached.get("fetched_at", 0))
        cached_paths = cached.get("paths") or []
        cached_url = cached.get("url") or ""
        if (time.time() - fetched_at) <= cache_ttl_sec and cached_paths == auth_files and cached_url == url:
            results_by_path = cached.get("results") or {}
            # Sanity check shape.
            if isinstance(results_by_path, dict):
                use_cache = True
    except Exception:
        use_cache = False

if not use_cache:
    with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as ex:
        futs = {ex.submit(fetch_one, p): p for p in auth_files}
        for fut in concurrent.futures.as_completed(futs):
            p = futs[fut]
            try:
                results_by_path[p] = fut.result()
            except Exception:
                results_by_path[p] = {"ok": False, "reason": "exception"}
    try:
        with open(cache_file, "w", encoding="utf-8") as f:
            json.dump(
                {"fetched_at": time.time(), "paths": auth_files, "url": url, "results": results_by_path},
                f,
                separators=(",", ":"),
            )
    except Exception:
        pass

def label_for_seconds(seconds, fallback):
    if not seconds:
        return fallback
    minutes = max(0, int(seconds // 60))
    minutes_per_hour = 60
    minutes_per_day = 24 * minutes_per_hour
    minutes_per_week = 7 * minutes_per_day
    minutes_per_month = 30 * minutes_per_day
    rounding_bias = 3

    if minutes <= minutes_per_day + rounding_bias:
        hours = max(1, (minutes + rounding_bias) // minutes_per_hour)
        return f"{hours}h"
    if minutes <= minutes_per_week + rounding_bias:
        return "weekly"
    if minutes <= minutes_per_month + rounding_bias:
        return "monthly"
    return "annual"

def pretty_label(label):
    if not label:
        return label
    return label[0].upper() + label[1:] if label[0].isalpha() else label

def format_reset(reset_at):
    if not reset_at:
        return None
    try:
        dt_reset = dt.datetime.fromtimestamp(int(reset_at), tz=dt.timezone.utc).astimezone()
    except Exception:
        return None
    now_dt = dt.datetime.now().astimezone()
    t = dt_reset.strftime("%H:%M")
    if dt_reset.date() == now_dt.date():
        return t
    day = dt_reset.strftime("%d").lstrip("0")
    month = dt_reset.strftime("%b")
    return f"{t} on {day} {month}"

def format_window(window, fallback_label):
    if not isinstance(window, dict):
        return None
    used = window.get("used_percent")
    if used is None:
        return None
    label = pretty_label(label_for_seconds(window.get("limit_window_seconds"), fallback_label))
    reset = format_reset(window.get("reset_at"))
    if reset:
        return f"{label} limit: {used}% used (resets {reset})"
    return f"{label} limit: {used}% used"

if mode == "status_blocks":
    for p in auth_files:
        r = results_by_path.get(p) or {}
        print(f"@@ {name_for(p)}")
        if not r.get("ok"):
            print("(unavailable)")
            continue
        primary = format_window(r.get("primary") or {}, "5h")
        secondary = format_window(r.get("secondary") or {}, "weekly")
        if primary:
            print(primary)
        if secondary:
            print(secondary)
        if not primary and not secondary:
            print("(unavailable)")
    sys.exit(0)

if mode == "best":
    now = int(time.time())
    best = None
    fallback = None

    for p in auth_files:
        r = results_by_path.get(p) or {}
        if not r.get("ok"):
            continue
        weekly = int(r.get("weekly_remaining", -1))
        fiveh = int(r.get("fiveh_remaining", -1))
        if weekly < 0 or fiveh < 0:
            continue

        primary = r.get("primary") or {}
        secondary = r.get("secondary") or {}

        wreset = int(secondary.get("reset_at") or 0)
        freset = int(primary.get("reset_at") or 0)

        ttr_weekly = unknown_reset_ttr_sec
        if wreset > 0:
            ttr_weekly = wreset - now
            if ttr_weekly < 1:
                ttr_weekly = 1

        ttr_fiveh = unknown_reset_ttr_sec
        if freset > 0:
            ttr_fiveh = freset - now
            if ttr_fiveh < 1:
                ttr_fiveh = 1

        # Fallback candidate, even if 5h is unusable.
        if fallback is None:
            fallback = (fiveh, ttr_fiveh, p)
        else:
            bfiveh, bttr, _ = fallback
            if fiveh > bfiveh or (fiveh == bfiveh and ttr_fiveh < bttr):
                fallback = (fiveh, ttr_fiveh, p)

        if fiveh <= fiveh_unusable:
            continue

        if best is None:
            best = (weekly, fiveh, ttr_weekly, wreset, p)
            continue

        bweekly, bfiveh, bttr, bwreset, _ = best

        # Maximize weekly urgency: weekly/ttr_weekly
        lhs = weekly * bttr
        rhs = bweekly * ttr_weekly
        if lhs > rhs:
            best = (weekly, fiveh, ttr_weekly, wreset, p)
        elif lhs == rhs:
            # Tie-break: weekly remaining, then 5h remaining, then earlier weekly reset.
            if weekly > bweekly:
                best = (weekly, fiveh, ttr_weekly, wreset, p)
            elif weekly == bweekly:
                if fiveh > bfiveh:
                    best = (weekly, fiveh, ttr_weekly, wreset, p)
                elif fiveh == bfiveh:
                    if wreset and bwreset:
                        if wreset < bwreset:
                            best = (weekly, fiveh, ttr_weekly, wreset, p)
                    elif wreset and not bwreset:
                        best = (weekly, fiveh, ttr_weekly, wreset, p)

    chosen_path = None
    if best is not None:
        chosen_path = best[-1]
    elif fallback is not None:
        chosen_path = fallback[-1]

    if chosen_path:
        print(name_for(chosen_path))
        sys.exit(0)
    sys.exit(1)

sys.exit(2)
PY
}

pick_best_account_by_quota() {
  ensure_dirs
  shopt -s nullglob

  local -a files=()
  files=( "$DATA_DIR"/*.auth.json )
  (( ${#files[@]} == 0 )) && return 1

  local out=""
  out="$(usage_bulk_tool best "${files[@]}" || true)"
  [[ -n "${out:-}" ]] || return 1
  echo "$out"
}

prompt_account_name() {
  local ans
  read -r -p "Enter a name for the CURRENT logged-in account (e.g., bashar, tazrin): " ans
  [[ -z "${ans:-}" ]] && die "Account name cannot be empty."
  echo "$ans"
}

backup_current_to() {
  # Requires ~/.codex/auth.json to exist
  local name="$1"
  assert_auth_present_or_hint

  local dest; dest="$(auth_path_for "$name")"

  if [[ -f "$dest" ]]; then
    local current_id dest_id
    current_id="$(auth_identity_for_file "$AUTH_FILE")"
    dest_id="$(auth_identity_for_file "$dest")"
    if [[ -n "$current_id" && -n "$dest_id" && "$current_id" != "$dest_id" ]]; then
      die "Refusing to overwrite '${name}': current auth belongs to a different account.
If you logged in outside the switcher, run: $0 save <new-name>
Or switch after syncing with: $0 switch <name>"
    fi
  fi

  note "Saving current auth.json to ${dest}..."
  cp -p "$AUTH_FILE" "$dest"
  ok "Saved."
}

extract_to_codex() {
  local authfile="$1"

  [[ -f "$authfile" ]] || die "Account auth file not found: $authfile"

  note "Activating $(basename "$authfile")..."
  mkdir -p "$CODEX_HOME"
  cp -p "$authfile" "$AUTH_FILE"
  ok "Activated auth.json into ~/.codex."
}

resolve_current_name_or_prompt() {
  # If CURRENT unknown but ~/.codex exists, ask user to name it so we can save it.
  load_state

  if [[ -f "$AUTH_FILE" ]]; then
    local current_id; current_id="$(auth_identity_for_file "$AUTH_FILE")"
    if [[ -n "$current_id" ]]; then
      local matched=""
      matched="$(match_saved_account_by_identity "$current_id" || true)"
      if [[ -n "$matched" ]]; then
        if [[ "${CURRENT:-}" != "$matched" ]]; then
          note "Detected current auth matches saved account '${matched}'. Updating state."
          PREVIOUS="${CURRENT:-}"
          CURRENT="$matched"
          save_state "$CURRENT" "$PREVIOUS"
        fi
        return 0
      fi

      # If state says we're on CURRENT but auth.json identity doesn't match, clear CURRENT so we prompt/back up safely.
      if [[ -n "${CURRENT:-}" ]]; then
        local current_saved_id=""
        local current_saved_path=""
        current_saved_path="$(auth_path_for "$CURRENT")"
        if [[ -f "$current_saved_path" ]]; then
          current_saved_id="$(auth_identity_for_file "$current_saved_path")"
        fi
        if [[ -n "$current_saved_id" && "$current_saved_id" != "$current_id" ]]; then
          note "Current auth doesn't match saved '${CURRENT}'."
          CURRENT=""
        fi
      fi
    fi
  fi

  if [[ -z "${CURRENT:-}" && -f "$AUTH_FILE" ]]; then
    local named; named="$(prompt_account_name)"
    backup_current_to "$named"
    PREVIOUS=""        # No meaningful previous yet
    CURRENT="$named"
    save_state "$CURRENT" "$PREVIOUS"
  fi
}

# ------------- commands -------------
cmd_list() {
  ensure_dirs
  shopt -s nullglob
  local -a files=()
  files=( "$DATA_DIR"/*.auth.json )
  if (( ${#files[@]} == 0 )); then
    echo "(no accounts saved yet)"
    return 0
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    for f in "${files[@]}"; do
      echo " - $(basename "${f%%.auth.json}" .auth.json)"
      echo "  Usage: (unavailable)"
    done
    return 0
  fi

  # One python process; concurrent HTTP requests; cache reused briefly across runs.
  local blocks=""
  blocks="$(usage_bulk_tool status_blocks "${files[@]}" || true)"
  if [[ -z "${blocks//[[:space:]]/}" ]]; then
    for f in "${files[@]}"; do
      echo " - $(basename "${f%%.auth.json}" .auth.json)"
      echo "  Usage: (unavailable)"
    done
    return 0
  fi

  local current_name=""
  while IFS= read -r line; do
    if [[ "$line" == "@@"* ]]; then
      current_name="${line#@@ }"
      echo " - ${current_name}"
      echo "  Usage:"
    else
      printf '    %s\n' "$line"
    fi
  done <<<"$blocks"
}

cmd_current() {
  load_state
  if [[ -n "${CURRENT:-}" ]]; then
    echo "Current:  $CURRENT"
  else
    echo "Current:  (unknown — no state recorded yet)"
  fi
  if [[ -n "${PREVIOUS:-}" ]]; then
    echo "Previous: $PREVIOUS"
  fi
  if [[ -n "${CURRENT:-}" ]]; then
    echo "Usage (current: ${CURRENT}):"
    local lines=""
    lines="$(usage_status_lines_for_auth "$AUTH_FILE")"
    if [[ -n "$lines" ]]; then
      printf '%s\n' "$lines" | sed 's/^/  /'
    else
      echo "  (unavailable)"
    fi
  else
    echo "Usage (auth.json):"
    local lines=""
    lines="$(usage_status_lines_for_auth "$AUTH_FILE")"
    if [[ -n "$lines" ]]; then
      printf '%s\n' "$lines" | sed 's/^/  /'
    else
      echo "  (unavailable)"
    fi
  fi
}

cmd_save() {
  # Save the *currently logged-in* ~/.codex under a name
  ensure_dirs
  assert_auth_present_or_hint
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    name="$(prompt_account_name)"
  fi
  backup_current_to "$name"

  # Update CURRENT, leave PREVIOUS as-is if already set
  load_state
  PREVIOUS="${CURRENT:-}"
  CURRENT="$name"
  save_state "$CURRENT" "$PREVIOUS"
}

cmd_add() {
  # Add a NEW account slot:
  #  - If ~/.codex exists, back it up under CURRENT (or prompt for a name if unknown)
  #  - Clear auth.json so user can run `codex login` for the NEW name
  #  - Do NOT create the auth file for the new one yet; that happens after they log in and run save/switch
  ensure_dirs
  resolve_current_name_or_prompt   # backs up & sets CURRENT if needed

  local newname="${1:-}"; [[ -z "$newname" ]] && die "Usage: $0 add <new-account-name>"

  if [[ -f "$AUTH_FILE" ]]; then
    note "Clearing ~/.codex/auth.json to prepare login for '${newname}'..."
    rm -f "$AUTH_FILE"
  fi
  ok "Ready. Now run: ${CODENAME} login  (to authenticate '${newname}')"
  echo "After login completes, run: $0 save ${newname}   (to store the new account)"
}

cmd_switch() {
  # Switch to an existing saved account by name:
  #  - Ensure the target auth exists
  #  - If ~/.codex exists, back it up under CURRENT (or prompt to name it)
  #  - Copy the target auth.json into ~/.codex
  local target="${1:-}"
  if [[ -z "$target" ]]; then
    target="$(pick_best_account_by_quota)" || die "Unable to determine best account (usage unavailable). Provide a name."
    note "Auto-selecting account (max weekly urgency; excludes 5h <= ${AUTO_SWITCH_FIVEH_UNUSABLE_PCT}%): ${target}"
  fi

  ensure_dirs
  resolve_current_name_or_prompt   # may back up and set CURRENT if previously unknown

  local authfile; authfile="$(auth_path_for "$target")"
  [[ -f "$authfile" ]] || die "No saved account named '${target}'. Use '$0 list' to see options."

  load_state
  if [[ -n "${CURRENT:-}" && "$CURRENT" == "$target" ]]; then
    ok "Already on auto-selected account: ${CURRENT}"
    return 0
  fi

  if [[ -f "$AUTH_FILE" ]]; then
    # Always back up current before switching
    if [[ -z "${CURRENT:-}" ]]; then
      # Should not happen after resolve_current_name_or_prompt, but double-guard:
      CURRENT="$(prompt_account_name)"
    fi
    backup_current_to "$CURRENT"
  fi

  note "Switching to '${target}'..."
  extract_to_codex "$authfile"

  # Update state
  load_state
  PREVIOUS="${CURRENT:-}"
  CURRENT="$target"
  save_state "$CURRENT" "$PREVIOUS"
  ok "Switched. Current account: ${CURRENT}"
}

cmd_help() {
  cat <<EOF
codex-accounts.sh — manage multiple Codex CLI accounts

USAGE
  $0 list
      Show all saved accounts (from ${DATA_DIR}) and Codex usage.

  $0 current
      Show current and previous accounts from the state and Codex usage.

  $0 save [<name>]
      Copy the current ~/.codex/auth.json into ${DATA_DIR}/<name>.auth.json.
      If <name> is omitted, you'll be prompted.

  $0 add <name>
      Prepare to add a new account:
        - backs up current (prompting for its name if unknown),
        - clears ~/.codex/auth.json so you can run 'codex login',
        - after login, run: $0 save <name>

  $0 switch [<name>]
      Switch to an existing saved account (name is optional).
      Backs up current first, then activates <name>.
      If <name> is omitted, auto-selects using usage + reset times:
        - excludes accounts with missing usage
        - excludes accounts with 5h remaining <= ${AUTO_SWITCH_FIVEH_UNUSABLE_PCT}%
        - picks the account with the highest weekly urgency (weekly_remaining / time_to_weekly_reset)

NOTES
  - Uses only ~/.codex/auth.json; other ~/.codex files are left untouched.
  - If ~/.codex is missing when saving/adding, you'll be prompted to login first.
  - Usage output requires ChatGPT login tokens; API-key-only logins won't show usage.
  - Install Codex if needed:  brew install codex
EOF
}

# ------------- main -------------
main() {
  ensure_dirs

  local cmd="${1:-help}"; shift || true
  case "$cmd" in
    list)    cmd_list "$@";;
    current) cmd_current "$@";;
    save)    cmd_save "$@";;
    add)     cmd_add "$@";;
    switch)  cmd_switch "$@";;
    help|--help|-h) cmd_help;;
    *) die "Unknown command: $cmd. See '$0 help'.";;
  esac
}

main "$@"
