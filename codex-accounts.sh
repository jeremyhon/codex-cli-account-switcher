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

usage_quota_score_for_auth() {
  # Output: "<score> <weekly_remaining> <fiveh_remaining>" (ints), or empty on failure.
  local auth_file="$1"
  if ! command -v python3 >/dev/null 2>&1; then
    return 0
  fi

  python3 - "$auth_file" "$CODEX_HOME/config.toml" <<'PY'
import json
import os
import re
import sys
import urllib.error
import urllib.request

auth_file = sys.argv[1]
config_file = sys.argv[2]

try:
    with open(auth_file, "r", encoding="utf-8") as f:
        auth = json.load(f)
except Exception:
    sys.exit(0)

tokens = auth.get("tokens") or {}
access_token = tokens.get("access_token") or ""
account_id = tokens.get("account_id") or ""
if not access_token:
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
except Exception:
    sys.exit(0)

try:
    payload = json.loads(body)
except Exception:
    sys.exit(0)

rate_limit = payload.get("rate_limit") or {}

def remaining_percent(window):
    if not isinstance(window, dict):
        return None
    used = window.get("used_percent")
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

fiveh_remaining = remaining_percent(rate_limit.get("primary_window"))
weekly_remaining = remaining_percent(rate_limit.get("secondary_window"))

if fiveh_remaining is None and weekly_remaining is None:
    sys.exit(0)

fiveh_remaining = fiveh_remaining if fiveh_remaining is not None else 0
weekly_remaining = weekly_remaining if weekly_remaining is not None else 0

# Heuristic: weekly counts double.
score = weekly_remaining * 2 + fiveh_remaining
print(f"{score} {weekly_remaining} {fiveh_remaining}")
PY
}

pick_best_account_by_quota() {
  ensure_dirs
  shopt -s nullglob

  local best_name=""
  local best_score=-1
  local best_weekly=-1
  local best_fiveh=-1

  for f in "$DATA_DIR"/*.auth.json; do
    local name; name="$(basename "${f%%.auth.json}" .auth.json)"
    local line=""
    line="$(usage_quota_score_for_auth "$f" || true)"
    [[ -z "$line" ]] && continue

    local score weekly fiveh
    read -r score weekly fiveh <<<"$line"
    [[ -z "${score:-}" ]] && continue

    if (( score > best_score )); then
      best_score=$score
      best_weekly=$weekly
      best_fiveh=$fiveh
      best_name="$name"
    elif (( score == best_score )); then
      if (( weekly > best_weekly )); then
        best_weekly=$weekly
        best_fiveh=$fiveh
        best_name="$name"
      elif (( weekly == best_weekly && fiveh > best_fiveh )); then
        best_fiveh=$fiveh
        best_name="$name"
      fi
    fi
  done

  [[ -n "$best_name" ]] || return 1
  echo "$best_name"
}

print_usage_summary_for_auth() {
  local auth_file="$1"
  local lines=""
  lines="$(usage_status_lines_for_auth "$auth_file")"
  if [[ -n "$lines" ]]; then
    echo "  Usage:"
    printf '%s\n' "$lines" | sed 's/^/    /'
  else
    echo "  Usage: (unavailable)"
  fi
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
  local any=0
  for f in "$DATA_DIR"/*.auth.json; do
    any=1
    echo " - $(basename "${f%%.auth.json}" .auth.json)"
    print_usage_summary_for_auth "$f"
  done
  [[ $any -eq 0 ]] && echo "(no accounts saved yet)"
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
    note "Auto-selecting account with most available quota: ${target}"
  fi

  ensure_dirs
  resolve_current_name_or_prompt   # may back up and set CURRENT if previously unknown

  local authfile; authfile="$(auth_path_for "$target")"
  [[ -f "$authfile" ]] || die "No saved account named '${target}'. Use '$0 list' to see options."

  load_state
  if [[ -n "${CURRENT:-}" && "$CURRENT" == "$target" ]]; then
    ok "Already on account with most available quota: ${CURRENT}"
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
      If <name> is omitted, auto-selects the account with the most
      available quota (weekly weighted heavier than 5h).

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
