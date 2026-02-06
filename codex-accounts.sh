#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CODEX_ACCOUNTS_PROG_NAME="$(basename -- "$0")" exec python3 "${SCRIPT_DIR}/codex_accounts.py" "$@"
