#!/usr/bin/env python3
from __future__ import annotations

import importlib
import importlib.util
import os
from pathlib import Path
from typing import Any, Callable


HeuristicFunc = Callable[..., Any]


def _load_callable_from_module(module_name: str, func_name: str) -> HeuristicFunc:
    module = importlib.import_module(module_name)
    func = getattr(module, func_name, None)
    if not callable(func):
        raise AttributeError(f"{module_name}:{func_name} is not callable")
    return func


def _load_callable_from_file(path: Path, func_name: str) -> HeuristicFunc:
    spec = importlib.util.spec_from_file_location("codex_accounts_custom_heuristic", path)
    if not spec or not spec.loader:
        raise RuntimeError(f"Unable to load module from {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    func = getattr(module, func_name, None)
    if not callable(func):
        raise AttributeError(f"{path}:{func_name} is not callable")
    return func


def load_heuristic(*, env_spec: str, default_path: Path, default_func: HeuristicFunc) -> HeuristicFunc:
    spec = env_spec.strip()

    if spec:
        target, func_name = (spec.split(":", 1) + ["choose_account"])[:2]
        func_name = func_name or "choose_account"
        target_path = Path(target).expanduser()

        if target.endswith(".py") or target_path.exists() or "/" in target:
            return _load_callable_from_file(target_path.resolve(), func_name)
        return _load_callable_from_module(target, func_name)

    if default_path.exists():
        return _load_callable_from_file(default_path, "choose_account")

    return default_func


def heuristic_env_spec() -> str:
    return os.getenv("CODEX_ACCOUNTS_HEURISTIC", "")
