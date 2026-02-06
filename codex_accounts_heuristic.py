#!/usr/bin/env python3
"""Default account selection heuristic for codex-accounts.

Users can replace this by either:
- Editing this file in-place, or
- Pointing CODEX_ACCOUNTS_HEURISTIC to another module/file that exposes
  `choose_account(candidates, *, now_ts, fiveh_unusable_pct, unknown_reset_ttr_sec)`.
"""

from __future__ import annotations

from typing import Any


def _to_int(value: Any, default: int) -> int:
    try:
        return int(value)
    except Exception:
        return default


def choose_account(
    candidates: list[dict[str, Any]],
    *,
    now_ts: int,
    fiveh_unusable_pct: int,
    unknown_reset_ttr_sec: int,
) -> str | None:
    """Pick the best account name from usage candidates.

    Candidate shape:
      {
        "name": str,
        "weekly_remaining": int,
        "fiveh_remaining": int,
        "weekly_reset_at": int,
        "fiveh_reset_at": int,
      }
    """

    best: tuple[int, int, int, int, str] | None = None
    fallback: tuple[int, int, str] | None = None

    for c in candidates:
        name = str(c.get("name") or "")
        if not name:
            continue

        weekly = _to_int(c.get("weekly_remaining"), -1)
        fiveh = _to_int(c.get("fiveh_remaining"), -1)
        if weekly < 0 or fiveh < 0:
            continue

        wreset = _to_int(c.get("weekly_reset_at"), 0)
        freset = _to_int(c.get("fiveh_reset_at"), 0)

        ttr_weekly = unknown_reset_ttr_sec
        if wreset > 0:
            ttr_weekly = wreset - now_ts
            if ttr_weekly < 1:
                ttr_weekly = 1

        ttr_fiveh = unknown_reset_ttr_sec
        if freset > 0:
            ttr_fiveh = freset - now_ts
            if ttr_fiveh < 1:
                ttr_fiveh = 1

        # Fallback candidate even if 5h is considered unusable.
        if fallback is None:
            fallback = (fiveh, ttr_fiveh, name)
        else:
            best_fiveh, best_ttr_fiveh, _ = fallback
            if fiveh > best_fiveh or (fiveh == best_fiveh and ttr_fiveh < best_ttr_fiveh):
                fallback = (fiveh, ttr_fiveh, name)

        # Hard usability filter.
        if fiveh <= fiveh_unusable_pct:
            continue

        if best is None:
            best = (weekly, fiveh, ttr_weekly, wreset, name)
            continue

        best_weekly, best_fiveh, best_ttr_weekly, best_wreset, _ = best

        # Maximize weekly urgency: weekly_remaining / time_to_weekly_reset
        # Compare ratios by cross multiplication.
        lhs = weekly * best_ttr_weekly
        rhs = best_weekly * ttr_weekly
        if lhs > rhs:
            best = (weekly, fiveh, ttr_weekly, wreset, name)
        elif lhs == rhs:
            # Tie-break: weekly remaining, then 5h remaining, then earlier weekly reset.
            if weekly > best_weekly:
                best = (weekly, fiveh, ttr_weekly, wreset, name)
            elif weekly == best_weekly:
                if fiveh > best_fiveh:
                    best = (weekly, fiveh, ttr_weekly, wreset, name)
                elif fiveh == best_fiveh:
                    if wreset and best_wreset:
                        if wreset < best_wreset:
                            best = (weekly, fiveh, ttr_weekly, wreset, name)
                    elif wreset and not best_wreset:
                        best = (weekly, fiveh, ttr_weekly, wreset, name)

    if best is not None:
        return best[-1]
    if fallback is not None:
        return fallback[-1]
    return None
