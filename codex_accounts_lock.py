#!/usr/bin/env python3
from __future__ import annotations

from contextlib import AbstractContextManager
from pathlib import Path
from typing import IO


try:
    import fcntl  # type: ignore
except Exception:  # pragma: no cover
    fcntl = None  # type: ignore


class FileLock(AbstractContextManager["FileLock"]):
    """Advisory lock backed by a lock file.

    On platforms without fcntl, this becomes a no-op lock.
    """

    def __init__(self, lock_path: Path):
        self.lock_path = lock_path
        self._fh: IO[str] | None = None

    def __enter__(self) -> "FileLock":
        self.lock_path.parent.mkdir(parents=True, exist_ok=True)
        self._fh = self.lock_path.open("a+", encoding="utf-8")
        if fcntl is not None:
            fcntl.flock(self._fh.fileno(), fcntl.LOCK_EX)
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        if self._fh is None:
            return
        try:
            if fcntl is not None:
                fcntl.flock(self._fh.fileno(), fcntl.LOCK_UN)
        finally:
            self._fh.close()
            self._fh = None
