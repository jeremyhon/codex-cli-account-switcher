#!/usr/bin/env bash
set -euo pipefail

#
# Resolve symlinks so that if `codex-accounts` is installed as a symlink
# (e.g. ~/bin/codex-accounts -> /usr/local/lib/.../codex-accounts.sh),
# we still find sibling python files next to the real script.
SCRIPT_PATH="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${SCRIPT_PATH}")" && pwd)"
CODEX_ACCOUNTS_PROG_NAME="$(basename -- "$0")" exec python3 "${SCRIPT_DIR}/codex_accounts.py" "$@"
