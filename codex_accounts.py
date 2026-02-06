#!/usr/bin/env python3
from __future__ import annotations

import concurrent.futures
import datetime as dt
import importlib
import importlib.util
import json
import os
import re
import shlex
import shutil
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Callable


CODENAME = "codex"
CODEX_HOME = Path.home() / ".codex"
AUTH_FILE = CODEX_HOME / "auth.json"
DATA_DIR = Path.home() / "codex-data"
STATE_DIR = Path.home() / ".codex-switch"
STATE_FILE = STATE_DIR / "state"

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


def _decode_shell_value(raw: str) -> str:
    raw = raw.strip()
    if raw == "":
        return ""
    try:
        parts = shlex.split(raw, posix=True)
        if parts:
            return parts[0]
    except Exception:
        pass
    if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in {'"', "'"}:
        return raw[1:-1]
    return raw


def load_state() -> tuple[str, str]:
    current = ""
    previous = ""
    if STATE_FILE.exists():
        try:
            for line in STATE_FILE.read_text(encoding="utf-8").splitlines():
                if "=" not in line:
                    continue
                key, value = line.split("=", 1)
                key = key.strip()
                if key == "CURRENT":
                    current = _decode_shell_value(value)
                elif key == "PREVIOUS":
                    previous = _decode_shell_value(value)
        except Exception:
            # Keep best effort state loading.
            pass
    return current, previous


def save_state(cur: str, prev: str) -> None:
    content = f"CURRENT={shlex.quote(cur)}\nPREVIOUS={shlex.quote(prev)}\n"
    STATE_FILE.write_text(content, encoding="utf-8")


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


def _load_base_url(config_file: Path) -> str:
    base_url = "https://chatgpt.com/backend-api"
    if config_file.exists():
        try:
            for line in config_file.read_text(encoding="utf-8").splitlines():
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
    if (
        base_url.startswith("https://chatgpt.com")
        or base_url.startswith("https://chat.openai.com")
    ) and "/backend-api" not in base_url:
        base_url = f"{base_url}/backend-api"
    return base_url


def _usage_url(config_file: Path) -> str:
    base_url = _load_base_url(config_file)
    path = "/wham/usage" if "/backend-api" in base_url else "/api/codex/usage"
    return f"{base_url}{path}"


def _remaining_percent(used: Any) -> int | None:
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


def _window_info(window: Any) -> dict[str, Any]:
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


def fetch_usage_for_auth(auth_file: Path, *, url: str | None = None, timeout: int = 10) -> dict[str, Any]:
    if url is None:
        url = _usage_url(CODEX_HOME / "config.toml")

    try:
        auth = json.loads(auth_file.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {"ok": False, "reason": "auth_missing"}
    except Exception:
        return {"ok": False, "reason": "auth_read_failed"}

    tokens = auth.get("tokens") or {}
    access_token = tokens.get("access_token") or ""
    account_id = tokens.get("account_id") or ""
    if not access_token:
        return {"ok": False, "reason": "no_access_token", "has_api_key": bool(auth.get("OPENAI_API_KEY"))}

    headers: dict[str, str] = {
        "Authorization": f"Bearer {access_token}",
        "User-Agent": "codex-cli",
    }
    if account_id:
        headers["ChatGPT-Account-Id"] = account_id

    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        return {"ok": False, "reason": f"http_{e.code}"}
    except Exception:
        return {"ok": False, "reason": "http_failed"}

    try:
        payload = json.loads(body)
    except Exception:
        return {"ok": False, "reason": "payload_parse_failed"}

    rate_limit = payload.get("rate_limit") or {}
    primary = _window_info(rate_limit.get("primary_window"))
    secondary = _window_info(rate_limit.get("secondary_window"))

    fiveh_remaining = _remaining_percent(primary.get("used_percent"))
    weekly_remaining = _remaining_percent(secondary.get("used_percent"))

    return {
        "ok": True,
        "primary": primary,
        "secondary": secondary,
        "fiveh_remaining": fiveh_remaining if fiveh_remaining is not None else -1,
        "weekly_remaining": weekly_remaining if weekly_remaining is not None else -1,
    }


def _label_for_seconds(seconds: Any, fallback: str) -> str:
    if not seconds:
        return fallback
    minutes = max(0, int(int(seconds) // 60))
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


def _pretty_label(label: str) -> str:
    if not label:
        return label
    return (label[0].upper() + label[1:]) if label[0].isalpha() else label


def _format_reset(reset_at: Any) -> str | None:
    if reset_at is None:
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


def _format_window(window: dict[str, Any], fallback_label: str) -> str | None:
    if not isinstance(window, dict):
        return None
    used = window.get("used_percent")
    if used is None:
        return None
    label = _pretty_label(_label_for_seconds(window.get("limit_window_seconds"), fallback_label))
    reset = _format_reset(window.get("reset_at"))
    if reset:
        return f"{label} limit: {used}% used (resets {reset})"
    return f"{label} limit: {used}% used"


def usage_status_lines_for_auth(auth_file: Path) -> list[str]:
    result = fetch_usage_for_auth(auth_file)
    if not result.get("ok"):
        return []
    lines: list[str] = []
    primary = _format_window(result.get("primary") or {}, "5h")
    secondary = _format_window(result.get("secondary") or {}, "weekly")
    if primary:
        lines.append(primary)
    if secondary:
        lines.append(secondary)
    return lines


def fetch_usage_bulk(auth_files: list[Path]) -> dict[str, dict[str, Any]]:
    if not auth_files:
        return {}

    ensure_dirs()
    url = _usage_url(CODEX_HOME / "config.toml")
    paths = [str(p) for p in auth_files]

    if USAGE_CACHE_TTL_SEC > 0 and USAGE_CACHE_FILE.exists():
        try:
            cached = json.loads(USAGE_CACHE_FILE.read_text(encoding="utf-8"))
            fetched_at = float(cached.get("fetched_at", 0))
            cached_paths = cached.get("paths") or []
            cached_url = cached.get("url") or ""
            if (time.time() - fetched_at) <= USAGE_CACHE_TTL_SEC and cached_paths == paths and cached_url == url:
                results = cached.get("results") or {}
                if isinstance(results, dict):
                    return results
        except Exception:
            pass

    results: dict[str, dict[str, Any]] = {}
    max_workers = max(1, min(USAGE_FETCH_CONCURRENCY, len(auth_files)))

    def _task(path: Path) -> tuple[str, dict[str, Any]]:
        return str(path), fetch_usage_for_auth(path, url=url)

    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as ex:
        futs = [ex.submit(_task, p) for p in auth_files]
        for fut in concurrent.futures.as_completed(futs):
            try:
                path_str, result = fut.result()
            except Exception:
                continue
            results[path_str] = result

    try:
        USAGE_CACHE_FILE.write_text(
            json.dumps(
                {"fetched_at": time.time(), "paths": paths, "url": url, "results": results},
                separators=(",", ":"),
            ),
            encoding="utf-8",
        )
    except Exception:
        pass

    return results


def _default_choose_account(
    candidates: list[dict[str, Any]],
    *,
    now_ts: int,
    fiveh_unusable_pct: int,
    unknown_reset_ttr_sec: int,
) -> str | None:
    # Fallback implementation only used if external heuristic module cannot be loaded.
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


def _load_callable_from_module(module_name: str, func_name: str) -> Callable[..., Any]:
    module = importlib.import_module(module_name)
    func = getattr(module, func_name, None)
    if not callable(func):
        raise AttributeError(f"{module_name}:{func_name} is not callable")
    return func


def _load_callable_from_file(path: Path, func_name: str) -> Callable[..., Any]:
    spec = importlib.util.spec_from_file_location("codex_accounts_custom_heuristic", path)
    if not spec or not spec.loader:
        raise RuntimeError(f"Unable to load module from {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    func = getattr(module, func_name, None)
    if not callable(func):
        raise AttributeError(f"{path}:{func_name} is not callable")
    return func


def load_heuristic() -> Callable[..., Any]:
    # CODEX_ACCOUNTS_HEURISTIC supports either:
    # - /path/to/file.py[:function]
    # - module.path[:function]
    # default function name is choose_account
    env_spec = os.getenv("CODEX_ACCOUNTS_HEURISTIC", "").strip()
    default_path = Path(__file__).resolve().with_name("codex_accounts_heuristic.py")

    if env_spec:
        target, func_name = (env_spec.split(":", 1) + ["choose_account"])[:2]
        func_name = func_name or "choose_account"
        target_path = Path(target).expanduser()
        try:
            if target.endswith(".py") or target_path.exists() or "/" in target:
                return _load_callable_from_file(target_path.resolve(), func_name)
            return _load_callable_from_module(target, func_name)
        except Exception as e:
            die(f"Failed to load heuristic '{env_spec}': {e}")

    try:
        if default_path.exists():
            return _load_callable_from_file(default_path, "choose_account")
    except Exception as e:
        note(f"Unable to load default heuristic module ({e}); using built-in fallback.")

    return _default_choose_account


def pick_best_account_by_quota() -> str | None:
    ensure_dirs()
    auth_files = sorted(DATA_DIR.glob("*.auth.json"))
    if not auth_files:
        return None

    results = fetch_usage_bulk(auth_files)
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

    heuristic = load_heuristic()
    picked = heuristic(
        candidates,
        now_ts=int(time.time()),
        fiveh_unusable_pct=AUTO_SWITCH_FIVEH_UNUSABLE_PCT,
        unknown_reset_ttr_sec=AUTO_SWITCH_UNKNOWN_RESET_TTR_SEC,
    )
    if not picked:
        return None

    picked_name = str(picked)
    valid_names = {p.name.removesuffix(".auth.json") for p in auth_files}
    if picked_name not in valid_names:
        die(f"Heuristic returned unknown account '{picked_name}'.")
    return picked_name


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
    current, previous = load_state()

    if AUTH_FILE.exists():
        current_id = auth_identity_for_file(AUTH_FILE)
        if current_id:
            matched = match_saved_account_by_identity(current_id)
            if matched:
                if current != matched:
                    note(f"Detected current auth matches saved account '{matched}'. Updating state.")
                    previous = current
                    current = matched
                    save_state(current, previous)
                return current, previous

            if current:
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
        save_state(current, previous)

    return current, previous


def cmd_list(prog: str) -> None:
    del prog
    ensure_dirs()
    current, _ = load_state()

    files = sorted(DATA_DIR.glob("*.auth.json"))
    if not files:
        print("(no accounts saved yet)")
        return

    results = fetch_usage_bulk(files)
    for auth_file in files:
        name = auth_file.name.removesuffix(".auth.json")
        marker = "*" if current and name == current else "-"
        print(f" {marker} {name}")
        print("  Usage:")

        result = results.get(str(auth_file)) or {}
        if not result.get("ok"):
            print("    (unavailable)")
            continue

        lines = []
        primary = _format_window(result.get("primary") or {}, "5h")
        secondary = _format_window(result.get("secondary") or {}, "weekly")
        if primary:
            lines.append(primary)
        if secondary:
            lines.append(secondary)

        if lines:
            for line in lines:
                print(f"    {line}")
        else:
            print("    (unavailable)")


def cmd_current(prog: str) -> None:
    del prog
    current, previous = load_state()
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
    if lines:
        for line in lines:
            print(f"  {line}")
    else:
        print("  (unavailable)")


def cmd_save(args: list[str], prog: str) -> None:
    ensure_dirs()
    assert_auth_present_or_hint()
    name = args[0] if args else ""
    if not name:
        name = prompt_account_name()

    backup_current_to(name, prog)

    current, _previous = load_state()
    save_state(name, current)


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

    current, _previous = load_state()
    if current and current == target:
        ok(f"Already on auto-selected account: {current}")
        return

    if AUTH_FILE.exists():
        if not current:
            current = prompt_account_name()
        backup_current_to(current, prog)

    note(f"Switching to '{target}'...")
    extract_to_codex(authfile)

    current2, _previous2 = load_state()
    save_state(target, current2)
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
