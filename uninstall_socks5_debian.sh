#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARGS=()

if [[ "${REMOVE_UFW_RULES:-1}" == "0" ]]; then
  ARGS+=("--keep-ufw-rules")
else
  ARGS+=("--remove-ufw-rules")
fi

if [[ -n "${PORT:-}" ]]; then
  ARGS+=("--port" "$PORT")
fi

if [[ "${REMOVE_XRAY:-0}" == "1" ]]; then
  ARGS+=("--purge")
fi

exec "$SCRIPT_DIR/manage_socks5.sh" remove "${ARGS[@]}" "$@"
