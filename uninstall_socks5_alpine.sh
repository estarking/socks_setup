#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARGS=()

REMOVE_FW_RULES_EFFECTIVE="${REMOVE_FW_RULES:-${REMOVE_UFW_RULES:-1}}"
if [[ "$REMOVE_FW_RULES_EFFECTIVE" == "0" ]]; then
  ARGS+=("--keep-fw-rules")
else
  ARGS+=("--remove-fw-rules")
fi

if [[ -n "${PORT:-}" ]]; then
  ARGS+=("--port" "$PORT")
fi

if [[ "${REMOVE_XRAY:-0}" == "1" ]]; then
  ARGS+=("--purge")
fi

exec "$SCRIPT_DIR/manage_socks5_alpine.sh" remove "${ARGS[@]}" "$@"
