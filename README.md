# Codex Accounts Switcher 🌀

**Easily manage multiple OpenAI Codex CLI accounts — switch, save, and restore with one command.**

The official [OpenAI Codex CLI](https://github.com/openai/codex) does **not support multi-account login**.  
Users must manually swap `~/.codex/auth.json` or re-authenticate every time they switch accounts — a painful process for developers who use multiple OpenAI accounts (for example, personal vs work).

I raised this issue here: [#4432](https://github.com/openai/codex/issues/4432)  
and also created a pull request adding multi-account support: [#4457](https://github.com/openai/codex/pull/4457)  
However, the feature hasn’t yet been merged or prioritized, so this standalone script fills that gap.

***I HAVE TESTED THIS ON MAC ONLY***


---

## 🔧 Installation

```bash
# Clone and install
git clone https://github.com/bashar94/codex-cli-account-switcher.git
cd codex-cli-account-switcher
chmod +x codex-accounts.sh

# Optionally make it global
sudo cp codex-accounts.sh codex_accounts.py codex_accounts_heuristic.py /usr/local/bin/
sudo ln -sf /usr/local/bin/codex-accounts.sh /usr/local/bin/codex-accounts
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
This script backs up each account’s `auth.json` file and lets you swap it instantly.

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
- Supports unlimited accounts — name-based switching.
- Automatically backs up the current account before changing.
- Shows the current and previous account states.
- Works cross-platform: macOS, Linux, WSL.
- Lightweight runtime deps (`bash` + `python3`).
- Helpful prompts if Codex isn’t installed or logged in yet.
- You can safely share this across machines (just copy `~/codex-data`).

## 🧪 Auto-pick Heuristic (switch without a name)
When you run `codex-accounts switch` without a name, the script tries to maximize total usable weekly quota over time:
- It excludes accounts where usage data is unavailable.
- It excludes accounts where the 5h window remaining is too low to be useful (default: `<= 5%`).
- Among the remaining accounts, it picks the one with the highest **weekly urgency**:
  `weekly_remaining / time_to_weekly_reset`
  (this biases toward draining accounts whose weekly window will refresh sooner).
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
