# Codex Accounts Switcher 🌀

**Easily manage multiple OpenAI Codex CLI accounts — switch, save, and restore with one command.**

Codex CLI currently works with one active login at a time. This tool gives you named account profiles and fast switching, so you can move between personal/work (or any other accounts) without repeated login flows.

Built for developers who regularly hit usage windows and want account switching to be predictable, quick, and scriptable.

***Tested primarily on macOS.***


---

## 🔧 Installation

```bash
# Clone and install
git clone https://github.com/jeremyhon/codex-cli-account-switcher.git
cd codex-cli-account-switcher
chmod +x codex-accounts.sh

# Optionally make it global
sudo mkdir -p /usr/local/lib/codex-accounts
sudo cp codex-accounts.sh codex_accounts*.py /usr/local/lib/codex-accounts/
sudo ln -sf /usr/local/lib/codex-accounts/codex-accounts.sh /usr/local/bin/codex-accounts
```

## 🚀 Usage
```
codex-accounts list
codex-accounts current
codex-accounts save <name>
codex-accounts add <name>
codex-accounts switch <name>
```
`list` and `current` will also display your Codex usage (5h + weekly) when available.
Usage is fetched directly from the Codex backend and requires ChatGPT login tokens in `~/.codex/auth.json` (API-key-only logins won’t show usage).
`list` marks the active account with `*`.

## ✨ Features
- Name-based multi-account management (`save`, `switch`, `add`) with unlimited saved profiles.
- Smart auto-pick mode (`codex-accounts switch` with no name) to select the best account based on usage + reset times.
- Quick usage visibility: `list` gives you a breakdown of your current usage across all your profiles.
- Built-in protection against accidentally overwriting a saved account with credentials from a different identity.
- Fast usage lookups with short-lived caching and concurrent usage fetches.
- Pluggable heuristic: swap selection logic without changing core command code.

### Examples
```
# Save your current login
codex-accounts save bashar

# Add a new account slot
codex-accounts add tazrin
codex login   # then run:
codex-accounts save tazrin

# Switch between accounts
codex-accounts switch bashar

# Auto-pick (no name) chooses an account based on usage + reset times
codex-accounts switch
```
## 📁 Data Locations
Codex stores its session data inside `~/.codex`.
This tool backs up each account’s `auth.json` file and lets you swap it instantly.

| Path                      | Purpose                              |
| ------------------------- | ------------------------------------ |
| `~/.codex`                      | Active Codex session folder          |
| `~/codex-data/<name>.auth.json` | Saved account backups                |
| `~/.codex-switch/state`         | Tracks current and previous accounts |

It’s safe to use — only `auth.json` is swapped; other Codex files are left untouched.

## ⚙️ Requirements
- macOS / Linux
- `bash`
- `python3`
- Codex CLI installed:
  - macOS: `brew install codex`
  - Linux: use your package manager or follow the [Codex CLI docs](https://developers.openai.com/codex/cli/)

## 🧠 Notes
- Works on macOS/Linux/WSL with lightweight runtime dependencies (`bash` + `python3`).
- Automatically backs up the active account before switching.
- Usage display/auto-pick needs ChatGPT login tokens (`access_token`) in `~/.codex/auth.json`.
- Saved profiles are portable: copy `~/codex-data` between machines.

## 🧪 Auto-pick Heuristic (switch without a name)
When you run `codex-accounts switch` without a name, the tool picks an account automatically so you can keep working with minimal manual decision-making:
- It excludes accounts where usage data is unavailable.
- It excludes accounts where the 5h window remaining is too low to be useful (default: `<= 5%`).
- Among the remaining accounts, it picks the one with the highest **weekly urgency**:
  `weekly_remaining / time_to_weekly_reset`
  (favoring accounts whose weekly quota can be used before it resets).
- If every account is excluded by the 5h filter, it falls back to the account with the most 5h remaining.

You can tune via env vars:
- `CODEX_ACCOUNTS_FIVEH_UNUSABLE_PCT` (default: `5`)
- `CODEX_ACCOUNTS_UNKNOWN_RESET_TTR_SEC` (default: `315360000` = 10 years; used when reset time is unknown)
- `CODEX_ACCOUNTS_USAGE_CONCURRENCY` (default: `6`; how many accounts to fetch usage for in parallel)
- `CODEX_ACCOUNTS_USAGE_CACHE_TTL_SEC` (default: `20`; reuses usage results briefly to speed up repeated `list`/auto-pick)

You can swap heuristics without changing core logic:
- `CODEX_ACCOUNTS_HEURISTIC=<module>[:function]`
- `CODEX_ACCOUNTS_HEURISTIC=/path/to/file.py[:function]`

Default heuristic implementation lives in `codex_accounts_heuristic.py`.

### Heuristic Plugin Contract
Custom heuristic function signature:

```python
def choose_account(
    candidates: list[dict[str, Any]],
    *,
    now_ts: int,
    fiveh_unusable_pct: int,
    unknown_reset_ttr_sec: int,
) -> str | None:
    ...
```

Each candidate has:
- `name` (saved account name)
- `weekly_remaining` (0-100, or negative when unavailable before filtering)
- `fiveh_remaining` (0-100, or negative when unavailable before filtering)
- `weekly_reset_at` (unix seconds, `0` if unknown)
- `fiveh_reset_at` (unix seconds, `0` if unknown)

Return the selected account `name` string (or `None` to indicate no choice).
