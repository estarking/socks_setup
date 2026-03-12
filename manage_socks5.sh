#!/usr/bin/env bash
set -euo pipefail

XRAY_CFG="/usr/local/etc/xray/config.json"
XRAY_SVC="xray"
META_FILE="/usr/local/etc/xray/socks5-manager.meta"

ACTION="${1:-help}"
shift || true

PORT=""
PROXY_USER=""
PROXY_PASS=""
ALLOW_IP=""
ENABLE_UFW=""
ALLOW_UDP=""
REMOVE_UFW_RULES="1"
PURGE_XRAY="0"
SHOW_PASS="0"
TEST_URL="https://google.com"
TEST_HOST="127.0.0.1"

CURRENT_PORT=""
CURRENT_USER=""
CURRENT_PASS=""
CURRENT_UDP=""
META_PORT=""
META_ALLOW_IP=""
META_ALLOW_UDP=""
META_ENABLE_UFW=""

usage() {
  cat <<'EOF'
Usage:
  manage_socks5.sh install [options]
  manage_socks5.sh update  [options]
  manage_socks5.sh remove  [options]
  manage_socks5.sh show [--show-pass]
  manage_socks5.sh status
  manage_socks5.sh test [--test-url URL] [--test-host HOST]
  manage_socks5.sh help

Install/Update options:
  --port <1-65535>
  --user <username>
  --pass <password>
  --allow-ip <cidr>          e.g. 1.2.3.4/32
  --enable-ufw | --disable-ufw
  --enable-udp | --disable-udp

Remove options:
  --port <port>              override old port when metadata is missing
  --allow-ip <cidr>          override old allow-ip when metadata is missing
  --remove-ufw-rules | --keep-ufw-rules
  --purge                    remove xray package via official installer

Show options:
  --show-pass

Test options:
  --test-url <url>           default: https://google.com
  --test-host <host>         default: 127.0.0.1

Examples:
  ./manage_socks5.sh install --port 8888 --user king
  ./manage_socks5.sh update --port 34578 --pass 'NewStrongPassword'
  ./manage_socks5.sh show --show-pass
  ./manage_socks5.sh test --test-url https://google.com
  ./manage_socks5.sh remove --purge
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_root() {
  [[ "${EUID}" -eq 0 ]] || die "Please run as root."
}

need_apt() {
  command -v apt-get >/dev/null 2>&1 || die "This script only supports Debian/Ubuntu (apt-get)."
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

is_valid_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] && ((p >= 1 && p <= 65535))
}

gen_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24
  else
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24
  fi
}

mask_secret() {
  local s="$1"
  local n="${#s}"
  if ((n <= 6)); then
    echo "******"
  else
    echo "${s:0:3}******${s:n-3:3}"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --port)
      PORT="${2:-}"
      shift 2
      ;;
    --user)
      PROXY_USER="${2:-}"
      shift 2
      ;;
    --pass)
      PROXY_PASS="${2:-}"
      shift 2
      ;;
    --allow-ip)
      ALLOW_IP="${2:-}"
      shift 2
      ;;
    --enable-ufw)
      ENABLE_UFW="1"
      shift
      ;;
    --disable-ufw)
      ENABLE_UFW="0"
      shift
      ;;
    --enable-udp)
      ALLOW_UDP="1"
      shift
      ;;
    --disable-udp)
      ALLOW_UDP="0"
      shift
      ;;
    --remove-ufw-rules)
      REMOVE_UFW_RULES="1"
      shift
      ;;
    --keep-ufw-rules)
      REMOVE_UFW_RULES="0"
      shift
      ;;
    --purge)
      PURGE_XRAY="1"
      shift
      ;;
    --show-pass)
      SHOW_PASS="1"
      shift
      ;;
    --test-url)
      TEST_URL="${2:-}"
      shift 2
      ;;
    --test-host)
      TEST_HOST="${2:-}"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
    esac
  done
}

load_meta() {
  [[ -f "$META_FILE" ]] || return 0
  while IFS='=' read -r k v; do
    case "$k" in
    PORT) META_PORT="$v" ;;
    ALLOW_IP) META_ALLOW_IP="$v" ;;
    ALLOW_UDP) META_ALLOW_UDP="$v" ;;
    ENABLE_UFW) META_ENABLE_UFW="$v" ;;
    esac
  done <"$META_FILE"
}

save_meta() {
  mkdir -p "$(dirname "$META_FILE")"
  {
    printf 'PORT=%s\n' "$PORT"
    printf 'ALLOW_IP=%s\n' "$ALLOW_IP"
    printf 'ALLOW_UDP=%s\n' "$ALLOW_UDP"
    printf 'ENABLE_UFW=%s\n' "$ENABLE_UFW"
  } >"$META_FILE"
  chmod 600 "$META_FILE"
}

read_current_config() {
  if [[ ! -f "$XRAY_CFG" ]]; then
    return 0
  fi
  need_cmd jq
  CURRENT_PORT="$(jq -r '[.inbounds[]? | select(.protocol=="socks") | .port][0] // empty' "$XRAY_CFG")"
  CURRENT_USER="$(jq -r '[.inbounds[]? | select(.protocol=="socks") | .settings.accounts[0].user][0] // empty' "$XRAY_CFG")"
  CURRENT_PASS="$(jq -r '[.inbounds[]? | select(.protocol=="socks") | .settings.accounts[0].pass][0] // empty' "$XRAY_CFG")"
  CURRENT_UDP="$(jq -r '[.inbounds[]? | select(.protocol=="socks") | .settings.udp][0] // false' "$XRAY_CFG")"
}

current_udp_to_flag() {
  if [[ "$CURRENT_UDP" == "true" ]]; then
    echo "1"
  else
    echo "0"
  fi
}

ensure_packages() {
  need_apt
  local pkgs=(curl ca-certificates jq openssl)
  if [[ "${ENABLE_UFW:-1}" == "1" ]]; then
    pkgs+=(ufw)
  fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y "${pkgs[@]}"
}

install_xray_if_needed() {
  if command -v xray >/dev/null 2>&1; then
    return 0
  fi
  echo "Installing Xray..."
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
}

backup_config_if_exists() {
  mkdir -p "$(dirname "$XRAY_CFG")"
  if [[ -f "$XRAY_CFG" ]]; then
    local backup="${XRAY_CFG}.bak.$(date +%Y%m%d_%H%M%S)"
    cp -a "$XRAY_CFG" "$backup"
    echo "Backup created: $backup"
  fi
}

write_config() {
  local udp_bool="false"
  [[ "$ALLOW_UDP" == "1" ]] && udp_bool="true"

  jq -n \
    --argjson port "$PORT" \
    --arg user "$PROXY_USER" \
    --arg pass "$PROXY_PASS" \
    --argjson udp "$udp_bool" \
    '{
      log: {loglevel: "warning"},
      inbounds: [
        {
          tag: "socks-in",
          listen: "0.0.0.0",
          port: $port,
          protocol: "socks",
          settings: {
            auth: "password",
            accounts: [{user: $user, pass: $pass}],
            udp: $udp
          }
        }
      ],
      outbounds: [
        {protocol: "freedom"}
      ]
    }' >"$XRAY_CFG"
}

validate_config() {
  need_cmd xray
  xray -test -config "$XRAY_CFG" >/dev/null
}

cleanup_ufw_rules() {
  local old_port="$1"
  local old_allow_ip="$2"
  local old_udp="$3"

  command -v ufw >/dev/null 2>&1 || return 0

  if [[ -n "$old_allow_ip" ]]; then
    ufw delete allow from "$old_allow_ip" to any port "$old_port" proto tcp >/dev/null 2>&1 || true
    if [[ "$old_udp" == "1" ]]; then
      ufw delete allow from "$old_allow_ip" to any port "$old_port" proto udp >/dev/null 2>&1 || true
    fi
  fi

  ufw delete allow "$old_port"/tcp >/dev/null 2>&1 || true
  if [[ "$old_udp" == "1" ]]; then
    ufw delete allow "$old_port"/udp >/dev/null 2>&1 || true
  fi
}

apply_ufw_rules() {
  [[ "$ENABLE_UFW" == "1" ]] || return 0
  command -v ufw >/dev/null 2>&1 || die "UFW not found."

  ufw --force enable >/dev/null 2>&1 || true

  if [[ -n "$ALLOW_IP" ]]; then
    ufw allow from "$ALLOW_IP" to any port "$PORT" proto tcp >/dev/null
    if [[ "$ALLOW_UDP" == "1" ]]; then
      ufw allow from "$ALLOW_IP" to any port "$PORT" proto udp >/dev/null
    fi
  else
    ufw allow "$PORT"/tcp >/dev/null
    if [[ "$ALLOW_UDP" == "1" ]]; then
      ufw allow "$PORT"/udp >/dev/null
    fi
  fi
}

restart_service() {
  systemctl daemon-reload
  systemctl enable "$XRAY_SVC" >/dev/null
  systemctl restart "$XRAY_SVC"
  systemctl is-active --quiet "$XRAY_SVC" || die "Service $XRAY_SVC is not active."
}

get_public_ip() {
  local ip=""
  ip="$(curl -4fsS https://google.com || true)"
  if [[ -z "$ip" ]]; then
    ip="$(curl -4fsS https://ipv4.icanhazip.com 2>/dev/null | tr -d '\r\n' || true)"
  fi
  echo "${ip:-<YOUR_SERVER_IP>}"
}

print_connection() {
  local host
  host="$(get_public_ip)"
  echo "Host: $host"
  echo "Port: $PORT"
  echo "Username: $PROXY_USER"
  echo "Password: $PROXY_PASS"
  echo "Proxy URL: socks5://${PROXY_USER}:${PROXY_PASS}@${host}:${PORT}"
  echo "Test: curl -x 'socks5h://${PROXY_USER}:${PROXY_PASS}@${host}:${PORT}' -sS https://google.com && echo"
}

validate_runtime_values() {
  is_valid_port "$PORT" || die "Invalid port: $PORT"
  [[ -n "$PROXY_USER" ]] || die "Username is empty."
  [[ -n "$PROXY_PASS" ]] || die "Password is empty."
  [[ "$ENABLE_UFW" == "0" || "$ENABLE_UFW" == "1" ]] || die "ENABLE_UFW must be 0 or 1."
  [[ "$ALLOW_UDP" == "0" || "$ALLOW_UDP" == "1" ]] || die "ALLOW_UDP must be 0 or 1."
}

prepare_install_values() {
  PORT="${PORT:-8888}"
  PROXY_USER="${PROXY_USER:-king}"
  PROXY_PASS="${PROXY_PASS:-$(gen_password)}"
  ENABLE_UFW="${ENABLE_UFW:-1}"
  ALLOW_UDP="${ALLOW_UDP:-1}"
}

prepare_update_values() {
  read_current_config
  [[ -f "$XRAY_CFG" ]] || die "Config file not found: $XRAY_CFG"
  [[ -n "$CURRENT_PORT" && -n "$CURRENT_USER" && -n "$CURRENT_PASS" ]] || die "Cannot read current SOCKS settings."

  load_meta
  PORT="${PORT:-$CURRENT_PORT}"
  PROXY_USER="${PROXY_USER:-$CURRENT_USER}"
  PROXY_PASS="${PROXY_PASS:-$CURRENT_PASS}"
  ENABLE_UFW="${ENABLE_UFW:-${META_ENABLE_UFW:-1}}"
  ALLOW_UDP="${ALLOW_UDP:-${META_ALLOW_UDP:-$(current_udp_to_flag)}}"
  ALLOW_IP="${ALLOW_IP:-${META_ALLOW_IP:-}}"
}

cmd_install() {
  need_root
  prepare_install_values
  validate_runtime_values

  ensure_packages
  load_meta
  read_current_config
  install_xray_if_needed
  backup_config_if_exists
  write_config
  validate_config

  if [[ "${META_ENABLE_UFW:-1}" == "1" ]]; then
    local old_port="${META_PORT:-${CURRENT_PORT:-$PORT}}"
    local old_ip="${META_ALLOW_IP:-}"
    local old_udp="${META_ALLOW_UDP:-1}"
    cleanup_ufw_rules "$old_port" "$old_ip" "$old_udp"
  fi
  apply_ufw_rules

  restart_service
  save_meta
  echo "Install/Apply completed."
  print_connection
}

cmd_update() {
  need_root
  ENABLE_UFW="${ENABLE_UFW:-1}"
  ensure_packages
  prepare_update_values
  validate_runtime_values

  local old_port old_ip old_udp old_enable
  old_port="${META_PORT:-$CURRENT_PORT}"
  old_ip="${META_ALLOW_IP:-}"
  old_udp="${META_ALLOW_UDP:-$(current_udp_to_flag)}"
  old_enable="${META_ENABLE_UFW:-1}"

  install_xray_if_needed
  backup_config_if_exists
  write_config
  validate_config

  if [[ "$old_enable" == "1" ]]; then
    cleanup_ufw_rules "$old_port" "$old_ip" "$old_udp"
  fi
  apply_ufw_rules

  restart_service
  save_meta
  echo "Update completed."
  print_connection
}

cmd_remove() {
  need_root
  read_current_config
  load_meta

  local old_port old_ip old_udp
  old_port="${PORT:-${META_PORT:-${CURRENT_PORT:-8888}}}"
  old_ip="${ALLOW_IP:-${META_ALLOW_IP:-}}"
  old_udp="${META_ALLOW_UDP:-${CURRENT_UDP:+$(current_udp_to_flag)}}"
  old_udp="${old_udp:-1}"

  if systemctl list-unit-files | grep -q "^${XRAY_SVC}\.service"; then
    systemctl stop "$XRAY_SVC" || true
    systemctl disable "$XRAY_SVC" || true
  fi

  if [[ "$REMOVE_UFW_RULES" == "1" ]]; then
    cleanup_ufw_rules "$old_port" "$old_ip" "$old_udp"
  fi

  rm -f "$XRAY_CFG" "$META_FILE"

  if [[ "$PURGE_XRAY" == "1" ]]; then
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove || true
  fi

  echo "Remove completed."
}

cmd_show() {
  need_cmd jq
  [[ -f "$XRAY_CFG" ]] || die "Config file not found: $XRAY_CFG"
  read_current_config
  load_meta

  [[ -n "$CURRENT_PORT" && -n "$CURRENT_USER" ]] || die "No SOCKS inbound found in config."
  local ip pass_out
  ip="$(get_public_ip)"
  if [[ "$SHOW_PASS" == "1" ]]; then
    pass_out="$CURRENT_PASS"
  else
    pass_out="$(mask_secret "$CURRENT_PASS")"
  fi

  echo "Service: $XRAY_SVC"
  echo "Host: $ip"
  echo "Port: $CURRENT_PORT"
  echo "Username: $CURRENT_USER"
  echo "Password: $pass_out"
  echo "UDP: $CURRENT_UDP"
  echo "ALLOW_IP(meta): ${META_ALLOW_IP:-<not set>}"
  echo "ENABLE_UFW(meta): ${META_ENABLE_UFW:-<not set>}"
}

cmd_status() {
  local active="inactive"
  if systemctl list-unit-files | grep -q "^${XRAY_SVC}\.service"; then
    active="$(systemctl is-active "$XRAY_SVC" || true)"
  fi
  echo "Service status: $active"

  if [[ -f "$XRAY_CFG" ]] && command -v jq >/dev/null 2>&1; then
    read_current_config
    if [[ -n "$CURRENT_PORT" ]]; then
      echo "Configured port: $CURRENT_PORT"
      if command -v ss >/dev/null 2>&1; then
        ss -ltnup 2>/dev/null | grep -E ":${CURRENT_PORT}\b" || true
      fi
    fi
  fi
}

cmd_test() {
  need_cmd curl
  need_cmd jq
  [[ -f "$XRAY_CFG" ]] || die "Config file not found: $XRAY_CFG"
  read_current_config
  [[ -n "$CURRENT_PORT" && -n "$CURRENT_USER" && -n "$CURRENT_PASS" ]] || die "Cannot read current SOCKS settings."

  local proxy_url
  proxy_url="socks5h://${CURRENT_USER}:${CURRENT_PASS}@${TEST_HOST}:${CURRENT_PORT}"
  echo "Testing proxy: ${TEST_HOST}:${CURRENT_PORT}"
  curl -x "$proxy_url" -sS --connect-timeout 8 --max-time 20 "$TEST_URL"
  echo
  echo "Test succeeded."
}

parse_args "$@"

case "$ACTION" in
install) cmd_install ;;
update) cmd_update ;;
remove | uninstall) cmd_remove ;;
show) cmd_show ;;
status) cmd_status ;;
test) cmd_test ;;
help | -h | --help) usage ;;
*)
  usage
  die "Unknown action: $ACTION"
  ;;
esac
