#!/usr/bin/env python3
from __future__ import annotations

import concurrent.futures
import datetime as dt
import json
import re
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

from codex_accounts_lock import FileLock


def load_base_url(config_file: Path) -> str:
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


def usage_url(config_file: Path) -> str:
    base_url = load_base_url(config_file)
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


def fetch_usage_for_auth(auth_file: Path, *, url: str, timeout_sec: int = 10) -> dict[str, Any]:
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
        return {
            "ok": False,
            "reason": "no_access_token",
            "has_api_key": bool(auth.get("OPENAI_API_KEY")),
        }

    headers: dict[str, str] = {
        "Authorization": f"Bearer {access_token}",
        "User-Agent": "codex-cli",
    }
    if account_id:
        headers["ChatGPT-Account-Id"] = account_id

    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout_sec) as resp:
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


def fetch_usage_bulk(
    auth_files: list[Path],
    *,
    config_file: Path,
    cache_file: Path,
    cache_ttl_sec: int,
    concurrency: int,
) -> dict[str, dict[str, Any]]:
    if not auth_files:
        return {}

    url = usage_url(config_file)
    paths = [str(p) for p in auth_files]
    auth_fingerprints: list[str] = []
    for p in auth_files:
        try:
            stat = p.stat()
            auth_fingerprints.append(f"{p}:{stat.st_mtime_ns}:{stat.st_size}")
        except Exception:
            auth_fingerprints.append(f"{p}:missing")
    cache_lock_file = cache_file.with_suffix(cache_file.suffix + ".lock")

    # Read-through cache with lock.
    if cache_ttl_sec > 0 and cache_file.exists():
        with FileLock(cache_lock_file):
            try:
                cached = json.loads(cache_file.read_text(encoding="utf-8"))
                fetched_at = float(cached.get("fetched_at", 0))
                cached_paths = cached.get("paths") or []
                cached_url = cached.get("url") or ""
                cached_auth_fingerprints = cached.get("auth_fingerprints") or []
                if (
                    (time.time() - fetched_at) <= cache_ttl_sec
                    and cached_paths == paths
                    and cached_url == url
                    and cached_auth_fingerprints == auth_fingerprints
                ):
                    results = cached.get("results") or {}
                    if isinstance(results, dict):
                        return results
            except Exception:
                pass

    results: dict[str, dict[str, Any]] = {}
    max_workers = max(1, min(concurrency, len(auth_files)))

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

    # Write-back cache with lock.
    if cache_ttl_sec > 0:
        with FileLock(cache_lock_file):
            try:
                cache_file.write_text(
                    json.dumps(
                        {
                            "fetched_at": time.time(),
                            "paths": paths,
                            "url": url,
                            "auth_fingerprints": auth_fingerprints,
                            "results": results,
                        },
                        separators=(",", ":"),
                    ),
                    encoding="utf-8",
                )
            except Exception:
                pass

    return results


def label_for_seconds(seconds: Any, fallback: str) -> str:
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


def pretty_label(label: str) -> str:
    if not label:
        return label
    return (label[0].upper() + label[1:]) if label[0].isalpha() else label


def format_reset(reset_at: Any) -> str | None:
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


def format_window(window: dict[str, Any], fallback_label: str) -> str | None:
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


def format_failure_line(result: dict[str, Any]) -> str:
    reason = str(result.get("reason") or "").strip()

    if reason == "http_401":
        return "Auth check: 401 Unauthorized (token invalid or expired)"
    if reason.startswith("http_"):
        return f"Usage fetch failed: HTTP {reason.split('_', 1)[1]}"
    if reason == "no_access_token":
        if result.get("has_api_key"):
            return "Auth check: missing ChatGPT access token (API-key-only auth)"
        return "Auth check: missing ChatGPT access token"
    if reason == "auth_missing":
        return "Auth check: auth.json missing"
    if reason == "auth_read_failed":
        return "Auth check: couldn't read auth.json"
    if reason == "payload_parse_failed":
        return "Usage fetch failed: invalid response payload"
    if reason == "http_failed":
        return "Usage fetch failed: network error"
    return f"Usage unavailable ({reason or 'unknown error'})"


def format_usage_lines(result: dict[str, Any]) -> list[str]:
    if not result.get("ok"):
        return [format_failure_line(result)]
    lines: list[str] = []
    primary = format_window(result.get("primary") or {}, "5h")
    secondary = format_window(result.get("secondary") or {}, "weekly")
    if primary:
        lines.append(primary)
    if secondary:
        lines.append(secondary)
    if not lines:
        return ["Usage unavailable (missing rate-limit windows)"]
    return lines
