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
  local target="${1:-}"; [[ -z "$target" ]] && die "Usage: $0 switch <account-name>"

  ensure_dirs
  resolve_current_name_or_prompt   # may back up and set CURRENT if previously unknown

  local authfile; authfile="$(auth_path_for "$target")"
  [[ -f "$authfile" ]] || die "No saved account named '${target}'. Use '$0 list' to see options."

  if [[ -f "$AUTH_FILE" ]]; then
    # Always back up current before switching
    load_state
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
      Show all saved accounts (from ${DATA_DIR}).

  $0 current
      Show current and previous accounts from the state.

  $0 save [<name>]
      Copy the current ~/.codex/auth.json into ${DATA_DIR}/<name>.auth.json.
      If <name> is omitted, you'll be prompted.

  $0 add <name>
      Prepare to add a new account:
        - backs up current (prompting for its name if unknown),
        - clears ~/.codex/auth.json so you can run 'codex login',
        - after login, run: $0 save <name>

  $0 switch <name>
      Switch to an existing saved account (name is mandatory).
      Backs up current first, then activates <name>.

NOTES
  - Uses only ~/.codex/auth.json; other ~/.codex files are left untouched.
  - If ~/.codex is missing when saving/adding, you'll be prompted to login first.
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
