#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import shutil
import sys
import time
from pathlib import Path
from typing import Any

from codex_accounts_heuristic_loader import heuristic_env_spec, load_heuristic
from codex_accounts_state import load_state, save_state
from codex_accounts_usage import fetch_usage_bulk, format_usage_lines


CODENAME = "codex"
CODEX_HOME = Path.home() / ".codex"
AUTH_FILE = CODEX_HOME / "auth.json"
DATA_DIR = Path.home() / "codex-data"
STATE_DIR = Path.home() / ".codex-switch"
STATE_FILE = STATE_DIR / "state"
STATE_LOCK_FILE = STATE_DIR / "state.lock"

AUTO_SWITCH_FIVEH_UNUSABLE_PCT = int(os.getenv("CODEX_ACCOUNTS_FIVEH_UNUSABLE_PCT", "5"))
AUTO_SWITCH_UNKNOWN_RESET_TTR_SEC = int(
    os.getenv("CODEX_ACCOUNTS_UNKNOWN_RESET_TTR_SEC", "315360000")
)  # 10 years

USAGE_FETCH_CONCURRENCY = int(os.getenv("CODEX_ACCOUNTS_USAGE_CONCURRENCY", "6"))
USAGE_CACHE_TTL_SEC = int(os.getenv("CODEX_ACCOUNTS_USAGE_CACHE_TTL_SEC", "20"))
USAGE_CACHE_FILE = STATE_DIR / "usage-cache.json"


def die(msg: str) -> None:
    print(f"[ERR] {msg}", file=sys.stderr)
    raise SystemExit(1)


def note(msg: str) -> None:
    print(f"[*] {msg}")


def ok(msg: str) -> None:
    print(f"[OK] {msg}")


def ensure_dirs() -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    STATE_DIR.mkdir(parents=True, exist_ok=True)


def auth_path_for(name: str) -> Path:
    return DATA_DIR / f"{name}.auth.json"


def auth_identity_for_file(auth_file: Path) -> str | None:
    try:
        data = json.loads(auth_file.read_text(encoding="utf-8"))
    except Exception:
        return None

    tokens = data.get("tokens") or {}
    account_id = tokens.get("account_id") or ""
    user_id = tokens.get("user_id") or ""
    if account_id:
        return f"account_id:{account_id}"
    if user_id:
        return f"user_id:{user_id}"
    return None


def match_saved_account_by_identity(identity: str) -> str | None:
    if not identity:
        return None
    for auth_file in sorted(DATA_DIR.glob("*.auth.json")):
        other_id = auth_identity_for_file(auth_file)
        if other_id and other_id == identity:
            return auth_file.name.removesuffix(".auth.json")
    return None


def maybe_update_state_from_active_auth() -> str | None:
    if not AUTH_FILE.exists():
        return None

    current_id = auth_identity_for_file(AUTH_FILE)
    if not current_id:
        return None

    matched = match_saved_account_by_identity(current_id)
    if not matched:
        return None

    current, previous = load_state(STATE_FILE, STATE_LOCK_FILE)
    if current != matched:
        note(f"Detected current auth matches saved account '{matched}'. Updating state.")
        save_state(STATE_FILE, STATE_LOCK_FILE, matched, current or previous)
    return matched


def maybe_sync_saved_auth_from_active(matched_name: str | None, prog: str) -> None:
    if not matched_name:
        return

    saved_auth = auth_path_for(matched_name)
    if not saved_auth.is_file() or not AUTH_FILE.is_file():
        return

    try:
        same_content = AUTH_FILE.read_bytes() == saved_auth.read_bytes()
    except Exception:
        return

    if same_content:
        return

    note(f"Detected updated active auth for '{matched_name}'. Syncing saved profile.")
    backup_current_to(matched_name, prog)


def assert_codex_present_or_hint() -> None:
    if not CODEX_HOME.is_dir():
        die(
            "~/.codex not found. You likely haven't logged in yet.\n"
            "Install Codex:  brew install codex\n"
            f"Then run:       {CODENAME} login"
        )


def assert_auth_present_or_hint() -> None:
    assert_codex_present_or_hint()
    if not AUTH_FILE.is_file():
        die(
            "~/.codex/auth.json not found. You likely haven't logged in yet.\n"
            f"Then run:       {CODENAME} login"
        )


def fetch_usage_results(auth_files: list[Path]) -> dict[str, dict[str, Any]]:
    return fetch_usage_bulk(
        auth_files,
        config_file=CODEX_HOME / "config.toml",
        cache_file=USAGE_CACHE_FILE,
        cache_ttl_sec=USAGE_CACHE_TTL_SEC,
        concurrency=USAGE_FETCH_CONCURRENCY,
    )


def usage_status_lines_for_auth(auth_file: Path) -> list[str]:
    results = fetch_usage_results([auth_file])
    result = results.get(str(auth_file)) or {}
    return format_usage_lines(result)


def _default_choose_account(
    candidates: list[dict[str, Any]],
    *,
    now_ts: int,
    fiveh_unusable_pct: int,
    unknown_reset_ttr_sec: int,
) -> str | None:
    best: tuple[int, int, int, int, str] | None = None
    fallback: tuple[int, int, str] | None = None

    for c in candidates:
        name = str(c.get("name") or "")
        if not name:
            continue
        try:
            weekly = int(c.get("weekly_remaining", -1))
            fiveh = int(c.get("fiveh_remaining", -1))
            wreset = int(c.get("weekly_reset_at") or 0)
            freset = int(c.get("fiveh_reset_at") or 0)
        except Exception:
            continue

        if weekly < 0 or fiveh < 0:
            continue

        ttr_weekly = unknown_reset_ttr_sec
        if wreset > 0:
            ttr_weekly = max(1, wreset - now_ts)

        ttr_fiveh = unknown_reset_ttr_sec
        if freset > 0:
            ttr_fiveh = max(1, freset - now_ts)

        if fallback is None or fiveh > fallback[0] or (fiveh == fallback[0] and ttr_fiveh < fallback[1]):
            fallback = (fiveh, ttr_fiveh, name)

        if fiveh <= fiveh_unusable_pct:
            continue

        if best is None:
            best = (weekly, fiveh, ttr_weekly, wreset, name)
            continue

        bweekly, bfiveh, bttr, bwreset, _ = best
        lhs = weekly * bttr
        rhs = bweekly * ttr_weekly
        if lhs > rhs:
            best = (weekly, fiveh, ttr_weekly, wreset, name)
        elif lhs == rhs:
            if weekly > bweekly:
                best = (weekly, fiveh, ttr_weekly, wreset, name)
            elif weekly == bweekly:
                if fiveh > bfiveh:
                    best = (weekly, fiveh, ttr_weekly, wreset, name)
                elif fiveh == bfiveh:
                    if wreset and bwreset and wreset < bwreset:
                        best = (weekly, fiveh, ttr_weekly, wreset, name)
                    elif wreset and not bwreset:
                        best = (weekly, fiveh, ttr_weekly, wreset, name)

    if best is not None:
        return best[-1]
    if fallback is not None:
        return fallback[-1]
    return None


def choose_best_account(candidates: list[dict[str, Any]]) -> str | None:
    default_path = Path(__file__).resolve().with_name("codex_accounts_heuristic.py")
    try:
        heuristic = load_heuristic(
            env_spec=heuristic_env_spec(),
            default_path=default_path,
            default_func=_default_choose_account,
        )
    except Exception as e:
        die(f"Failed to load heuristic '{heuristic_env_spec()}': {e}")

    picked = heuristic(
        candidates,
        now_ts=int(time.time()),
        fiveh_unusable_pct=AUTO_SWITCH_FIVEH_UNUSABLE_PCT,
        unknown_reset_ttr_sec=AUTO_SWITCH_UNKNOWN_RESET_TTR_SEC,
    )
    return str(picked) if picked else None


def pick_best_account_by_quota() -> str | None:
    ensure_dirs()
    auth_files = sorted(DATA_DIR.glob("*.auth.json"))
    if not auth_files:
        return None

    results = fetch_usage_results(auth_files)
    candidates: list[dict[str, Any]] = []
    for auth_file in auth_files:
        result = results.get(str(auth_file)) or {}
        if not result.get("ok"):
            continue

        primary = result.get("primary") or {}
        secondary = result.get("secondary") or {}
        candidates.append(
            {
                "name": auth_file.name.removesuffix(".auth.json"),
                "weekly_remaining": result.get("weekly_remaining", -1),
                "fiveh_remaining": result.get("fiveh_remaining", -1),
                "weekly_reset_at": secondary.get("reset_at", 0),
                "fiveh_reset_at": primary.get("reset_at", 0),
            }
        )

    if not candidates:
        return None

    picked = choose_best_account(candidates)
    if not picked:
        return None

    valid_names = {p.name.removesuffix(".auth.json") for p in auth_files}
    if picked not in valid_names:
        die(f"Heuristic returned unknown account '{picked}'.")
    return picked


def prompt_account_name() -> str:
    ans = input(
        "Enter a name for the CURRENT logged-in account (e.g., bashar, tazrin): "
    ).strip()
    if not ans:
        die("Account name cannot be empty.")
    return ans


def backup_current_to(name: str, prog: str) -> None:
    assert_auth_present_or_hint()
    dest = auth_path_for(name)

    if dest.exists():
        current_id = auth_identity_for_file(AUTH_FILE)
        dest_id = auth_identity_for_file(dest)
        if current_id and dest_id and current_id != dest_id:
            die(
                f"Refusing to overwrite '{name}': current auth belongs to a different account.\n"
                f"If you logged in outside the switcher, run: {prog} save <new-name>\n"
                f"Or switch after syncing with: {prog} switch <name>"
            )

    note(f"Saving current auth.json to {dest}...")
    shutil.copy2(AUTH_FILE, dest)
    ok("Saved.")


def extract_to_codex(authfile: Path) -> None:
    if not authfile.is_file():
        die(f"Account auth file not found: {authfile}")

    note(f"Activating {authfile.name}...")
    CODEX_HOME.mkdir(parents=True, exist_ok=True)
    shutil.copy2(authfile, AUTH_FILE)
    ok("Activated auth.json into ~/.codex.")


def resolve_current_name_or_prompt(prog: str) -> tuple[str, str]:
    current, previous = load_state(STATE_FILE, STATE_LOCK_FILE)

    matched = maybe_update_state_from_active_auth()
    if matched:
        return load_state(STATE_FILE, STATE_LOCK_FILE)

    if AUTH_FILE.exists():
        current_id = auth_identity_for_file(AUTH_FILE)
        if current_id and current:
            current_saved_path = auth_path_for(current)
            current_saved_id = (
                auth_identity_for_file(current_saved_path)
                if current_saved_path.exists()
                else None
            )
            if current_saved_id and current_saved_id != current_id:
                note(f"Current auth doesn't match saved '{current}'.")
                current = ""

    if not current and AUTH_FILE.exists():
        named = prompt_account_name()
        backup_current_to(named, prog)
        previous = ""
        current = named
        save_state(STATE_FILE, STATE_LOCK_FILE, current, previous)

    return current, previous


def cmd_list(prog: str) -> None:
    ensure_dirs()
    matched = maybe_update_state_from_active_auth()
    maybe_sync_saved_auth_from_active(matched, prog)
    current, _ = load_state(STATE_FILE, STATE_LOCK_FILE)

    files = sorted(DATA_DIR.glob("*.auth.json"))
    if not files:
        print("(no accounts saved yet)")
        return

    results = fetch_usage_results(files)
    for auth_file in files:
        name = auth_file.name.removesuffix(".auth.json")
        marker = "*" if current and name == current else "-"
        print(f" {marker} {name}")
        print("  Usage:")

        lines = format_usage_lines(results.get(str(auth_file)) or {})
        for line in lines:
            print(f"    {line}")


def cmd_current(prog: str) -> None:
    ensure_dirs()
    matched = maybe_update_state_from_active_auth()
    maybe_sync_saved_auth_from_active(matched, prog)
    current, previous = load_state(STATE_FILE, STATE_LOCK_FILE)

    if current:
        print(f"Current:  {current}")
    else:
        print("Current:  (unknown — no state recorded yet)")
    if previous:
        print(f"Previous: {previous}")

    if current:
        print(f"Usage (current: {current}):")
    else:
        print("Usage (auth.json):")

    lines = usage_status_lines_for_auth(AUTH_FILE)
    for line in lines:
        print(f"  {line}")


def cmd_save(args: list[str], prog: str) -> None:
    ensure_dirs()
    assert_auth_present_or_hint()

    name = args[0] if args else ""
    if not name:
        name = prompt_account_name()

    backup_current_to(name, prog)

    current, _previous = load_state(STATE_FILE, STATE_LOCK_FILE)
    save_state(STATE_FILE, STATE_LOCK_FILE, name, current)


def cmd_add(args: list[str], prog: str) -> None:
    ensure_dirs()
    resolve_current_name_or_prompt(prog)

    if not args or not args[0]:
        die(f"Usage: {prog} add <new-account-name>")
    newname = args[0]

    if AUTH_FILE.exists():
        note(f"Clearing ~/.codex/auth.json to prepare login for '{newname}'...")
        AUTH_FILE.unlink()

    ok(f"Ready. Now run: {CODENAME} login  (to authenticate '{newname}')")
    print(f"After login completes, run: {prog} save {newname}   (to store the new account)")


def cmd_switch(args: list[str], prog: str) -> None:
    target = args[0] if args else ""
    if not target:
        target = pick_best_account_by_quota() or ""
        if not target:
            die("Unable to determine best account (usage unavailable). Provide a name.")
        note(
            "Auto-selecting account "
            f"(max weekly urgency; excludes 5h <= {AUTO_SWITCH_FIVEH_UNUSABLE_PCT}%): {target}"
        )

    ensure_dirs()
    resolve_current_name_or_prompt(prog)

    authfile = auth_path_for(target)
    if not authfile.is_file():
        die(f"No saved account named '{target}'. Use '{prog} list' to see options.")

    current, _previous = load_state(STATE_FILE, STATE_LOCK_FILE)
    if current and current == target:
        ok(f"Already on auto-selected account: {current}")
        return

    if AUTH_FILE.exists():
        if not current:
            current = prompt_account_name()
        backup_current_to(current, prog)

    note(f"Switching to '{target}'...")
    extract_to_codex(authfile)

    current2, _previous2 = load_state(STATE_FILE, STATE_LOCK_FILE)
    save_state(STATE_FILE, STATE_LOCK_FILE, target, current2)
    ok(f"Switched. Current account: {target}")


def cmd_help(prog: str) -> None:
    print(
        f"""codex-accounts.sh — manage multiple Codex CLI accounts

USAGE
  {prog} list
      Show all saved accounts (from {DATA_DIR}) and Codex usage.

  {prog} current
      Show current and previous accounts from the state and Codex usage.

  {prog} save [<name>]
      Copy the current ~/.codex/auth.json into {DATA_DIR}/<name>.auth.json.
      If <name> is omitted, you'll be prompted.

  {prog} add <name>
      Prepare to add a new account:
        - backs up current (prompting for its name if unknown),
        - clears ~/.codex/auth.json so you can run 'codex login',
        - after login, run: {prog} save <name>

  {prog} switch [<name>]
      Switch to an existing saved account (name is optional).
      Backs up current first, then activates <name>.
      If <name> is omitted, auto-selects using usage + reset times:
        - excludes accounts with missing usage
        - excludes accounts with 5h remaining <= {AUTO_SWITCH_FIVEH_UNUSABLE_PCT}%
        - delegates selection to the configured heuristic

NOTES
  - Uses only ~/.codex/auth.json; other ~/.codex files are left untouched.
  - If ~/.codex is missing when saving/adding, you'll be prompted to login first.
  - list/current auto-sync a matched saved profile when active auth has newer tokens.
  - Usage output requires ChatGPT login tokens; API-key-only logins won't show usage.
  - Install Codex if needed:  brew install codex
  - Heuristic override: set CODEX_ACCOUNTS_HEURISTIC to module[:func] or /path/file.py[:func]
"""
    )


def main(argv: list[str]) -> int:
    ensure_dirs()
    prog = os.getenv("CODEX_ACCOUNTS_PROG_NAME", "").strip() or (
        os.path.basename(argv[0]) if argv else "codex-accounts"
    )

    if len(argv) < 2:
        cmd_help(prog)
        return 0

    cmd = argv[1]
    args = argv[2:]

    if cmd == "list":
        cmd_list(prog)
    elif cmd == "current":
        cmd_current(prog)
    elif cmd == "save":
        cmd_save(args, prog)
    elif cmd == "add":
        cmd_add(args, prog)
    elif cmd == "switch":
        cmd_switch(args, prog)
    elif cmd in {"help", "--help", "-h"}:
        cmd_help(prog)
    else:
        die(f"Unknown command: {cmd}. See '{prog} help'.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
