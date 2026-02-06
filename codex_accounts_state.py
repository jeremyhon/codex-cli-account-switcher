#!/usr/bin/env python3
from __future__ import annotations

import shlex
from pathlib import Path

from codex_accounts_lock import FileLock


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


def load_state(state_file: Path, state_lock_file: Path) -> tuple[str, str]:
    current = ""
    previous = ""
    with FileLock(state_lock_file):
        if state_file.exists():
            try:
                for line in state_file.read_text(encoding="utf-8").splitlines():
                    if "=" not in line:
                        continue
                    key, value = line.split("=", 1)
                    key = key.strip()
                    if key == "CURRENT":
                        current = _decode_shell_value(value)
                    elif key == "PREVIOUS":
                        previous = _decode_shell_value(value)
            except Exception:
                pass
    return current, previous


def save_state(state_file: Path, state_lock_file: Path, cur: str, prev: str) -> None:
    content = f"CURRENT={shlex.quote(cur)}\nPREVIOUS={shlex.quote(prev)}\n"
    with FileLock(state_lock_file):
        state_file.write_text(content, encoding="utf-8")
