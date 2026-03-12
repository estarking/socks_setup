#!/usr/bin/env bash
set -euo pipefail

XRAY_CFG="/usr/local/etc/xray/config.json"
XRAY_SVC="xray"
META_FILE="/usr/local/etc/xray/socks5-manager.meta"
XRAY_BIN="/usr/local/bin/xray"
OPENRC_SERVICE_FILE="/etc/init.d/xray"

ACTION="${1:-menu}"
shift || true

PORT=""
PROXY_USER=""
PROXY_PASS=""
ALLOW_IP=""
ENABLE_FIREWALL=""
ALLOW_UDP=""
REMOVE_FIREWALL_RULES="1"
PURGE_XRAY="0"
SHOW_PASS="0"
TEST_URL="https://api.ipify.org"
TEST_HOST="127.0.0.1"

CURRENT_PORT=""
CURRENT_USER=""
CURRENT_PASS=""
CURRENT_UDP=""
META_PORT=""
META_ALLOW_IP=""
META_ALLOW_UDP=""
META_ENABLE_FIREWALL=""

usage() {
  cat <<'EOF'
Usage:
  manage_socks5_alpine.sh                # interactive menu
  manage_socks5_alpine.sh menu           # interactive menu
  manage_socks5_alpine.sh install [options]
  manage_socks5_alpine.sh update  [options]
  manage_socks5_alpine.sh remove  [options]
  manage_socks5_alpine.sh show [--show-pass]
  manage_socks5_alpine.sh status
  manage_socks5_alpine.sh test [--test-url URL] [--test-host HOST]
  manage_socks5_alpine.sh help

Install/Update options:
  --port <1-65535>
  --user <username>
  --pass <password>
  --allow-ip <cidr>          e.g. 1.2.3.4/32
  --enable-fw | --disable-fw
  --enable-ufw | --disable-ufw   (legacy aliases)
  --enable-udp | --disable-udp

Remove options:
  --port <port>              override old port when metadata is missing
  --allow-ip <cidr>          override old allow-ip when metadata is missing
  --remove-fw-rules | --keep-fw-rules
  --remove-ufw-rules | --keep-ufw-rules   (legacy aliases)
  --purge                    remove xray package via official installer

Show options:
  --show-pass

Test options:
  --test-url <url>           default: https://api.ipify.org
  --test-host <host>         default: 127.0.0.1

Examples:
  ./manage_socks5_alpine.sh
  ./manage_socks5_alpine.sh install --port 8888 --user king
  ./manage_socks5_alpine.sh update --port 34578 --pass 'NewStrongPassword'
  ./manage_socks5_alpine.sh show --show-pass
  ./manage_socks5_alpine.sh test --test-url https://api.telegram.org
  ./manage_socks5_alpine.sh remove --purge
EOF
}

die() {
  echo "ERROR: $*" >&2
  return 1 2>/dev/null || exit 1
}

need_root() {
  [[ "${EUID}" -eq 0 ]] || die "Please run as root."
}

need_alpine() {
  command -v apk >/dev/null 2>&1 || die "Alpine package manager (apk) not found."
  [[ -f /etc/alpine-release ]] || die "This script is intended for Alpine Linux."
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
    --enable-fw | --enable-ufw)
      ENABLE_FIREWALL="1"
      shift
      ;;
    --disable-fw | --disable-ufw)
      ENABLE_FIREWALL="0"
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
    --remove-fw-rules | --remove-ufw-rules)
      REMOVE_FIREWALL_RULES="1"
      shift
      ;;
    --keep-fw-rules | --keep-ufw-rules)
      REMOVE_FIREWALL_RULES="0"
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

prompt_text() {
  local label="$1"
  local default="${2:-}"
  local value=""
  if [[ -n "$default" ]]; then
    read -r -p "${label} [${default}]: " value || true
  else
    read -r -p "${label}: " value || true
  fi
  if [[ -z "$value" ]]; then
    echo "$default"
  else
    echo "$value"
  fi
}

prompt_password_optional() {
  local label="$1"
  local value=""
  read -r -p "${label}: " value || true
  echo "$value"
}

prompt_yes_no() {
  local label="$1"
  local default="${2:-1}"
  local hint="y/N"
  local value=""

  if [[ "$default" == "1" ]]; then
    hint="Y/n"
  fi

  while true; do
    read -r -p "${label} [${hint}]: " value || true
    value="${value,,}"
    if [[ -z "$value" ]]; then
      echo "$default"
      return
    fi
    case "$value" in
    y | yes | 1)
      echo "1"
      return
      ;;
    n | no | 0)
      echo "0"
      return
      ;;
    *)
      echo "Please input y or n."
      ;;
    esac
  done
}

run_action_safe() {
  local fn="$1"
  set +e
  "$fn"
  local rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    echo "Action failed with exit code: $rc"
  fi
  return "$rc"
}

print_curl_test_cmd() {
  local host="$1"
  local port="$2"
  local user="$3"
  local pass="$4"
  local proxy_arg auth_arg
  printf -v proxy_arg '%q' "socks5h://${host}:${port}"
  printf -v auth_arg '%q' "${user}:${pass}"
  echo "curl --proxy ${proxy_arg} --proxy-user ${auth_arg} -sS https://api.ipify.org && echo"
}

load_meta() {
  [[ -f "$META_FILE" ]] || return 0
  while IFS='=' read -r k v; do
    case "$k" in
    PORT) META_PORT="$v" ;;
    ALLOW_IP) META_ALLOW_IP="$v" ;;
    ALLOW_UDP) META_ALLOW_UDP="$v" ;;
    ENABLE_FIREWALL) META_ENABLE_FIREWALL="$v" ;;
    ENABLE_UFW) META_ENABLE_FIREWALL="$v" ;;
    esac
  done <"$META_FILE"
}

save_meta() {
  mkdir -p "$(dirname "$META_FILE")"
  {
    printf 'PORT=%s\n' "$PORT"
    printf 'ALLOW_IP=%s\n' "$ALLOW_IP"
    printf 'ALLOW_UDP=%s\n' "$ALLOW_UDP"
    printf 'ENABLE_FIREWALL=%s\n' "$ENABLE_FIREWALL"
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
  need_alpine
  local pkgs=(bash curl ca-certificates jq openssl iptables)
  apk add --no-cache "${pkgs[@]}"
  if [[ "${ENABLE_FIREWALL:-1}" == "1" && ! -f /etc/init.d/iptables ]]; then
    apk add --no-cache iptables-openrc >/dev/null 2>&1 || true
  fi
}

install_xray_if_needed() {
  if command -v xray >/dev/null 2>&1; then
    return 0
  fi
  echo "Installing Xray..."
  set +e
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
  local rc=$?
  set -e
  command -v xray >/dev/null 2>&1 || die "Xray install failed (exit: $rc)."
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

iptables_rule_exists() {
  local proto="$1"
  local dport="$2"
  local allow_ip="${3:-}"
  if [[ -n "$allow_ip" ]]; then
    iptables -C INPUT -p "$proto" -s "$allow_ip" --dport "$dport" -j ACCEPT >/dev/null 2>&1
  else
    iptables -C INPUT -p "$proto" --dport "$dport" -j ACCEPT >/dev/null 2>&1
  fi
}

iptables_add_rule() {
  local proto="$1"
  local dport="$2"
  local allow_ip="${3:-}"
  if iptables_rule_exists "$proto" "$dport" "$allow_ip"; then
    return 0
  fi
  if [[ -n "$allow_ip" ]]; then
    iptables -I INPUT 1 -p "$proto" -s "$allow_ip" --dport "$dport" -j ACCEPT
  else
    iptables -I INPUT 1 -p "$proto" --dport "$dport" -j ACCEPT
  fi
}

iptables_delete_rule() {
  local proto="$1"
  local dport="$2"
  local allow_ip="${3:-}"
  while iptables_rule_exists "$proto" "$dport" "$allow_ip"; do
    if [[ -n "$allow_ip" ]]; then
      iptables -D INPUT -p "$proto" -s "$allow_ip" --dport "$dport" -j ACCEPT >/dev/null 2>&1 || break
    else
      iptables -D INPUT -p "$proto" --dport "$dport" -j ACCEPT >/dev/null 2>&1 || break
    fi
  done
}

save_firewall_rules_if_possible() {
  if [[ -f /etc/init.d/iptables ]]; then
    rc-update add iptables default >/dev/null 2>&1 || true
    rc-service iptables save >/dev/null 2>&1 || true
  fi
}

cleanup_firewall_rules() {
  local old_port="$1"
  local old_allow_ip="$2"
  local old_udp="$3"

  command -v iptables >/dev/null 2>&1 || return 0

  if [[ -n "$old_allow_ip" ]]; then
    iptables_delete_rule tcp "$old_port" "$old_allow_ip"
    if [[ "$old_udp" == "1" ]]; then
      iptables_delete_rule udp "$old_port" "$old_allow_ip"
    fi
  fi

  iptables_delete_rule tcp "$old_port"
  if [[ "$old_udp" == "1" ]]; then
    iptables_delete_rule udp "$old_port"
  fi

  save_firewall_rules_if_possible
}

apply_firewall_rules() {
  [[ "$ENABLE_FIREWALL" == "1" ]] || return 0
  command -v iptables >/dev/null 2>&1 || die "iptables not found."

  iptables_add_rule tcp "$PORT" "$ALLOW_IP"
  if [[ "$ALLOW_UDP" == "1" ]]; then
    iptables_add_rule udp "$PORT" "$ALLOW_IP"
  fi

  save_firewall_rules_if_possible
}

ensure_openrc_service() {
  local xray_bin
  xray_bin="$(command -v xray || true)"
  [[ -n "$xray_bin" ]] || xray_bin="$XRAY_BIN"

  mkdir -p /etc/init.d
  cat >"$OPENRC_SERVICE_FILE" <<EOF
#!/sbin/openrc-run
name="Xray"
description="Xray Service"
command="$xray_bin"
command_args="run -config $XRAY_CFG"
command_background="yes"
pidfile="/run/xray.pid"
output_log="/var/log/xray.log"
error_log="/var/log/xray.err.log"

depend() {
  need net
}

start_pre() {
  checkpath --directory /var/log
}
EOF
  chmod 755 "$OPENRC_SERVICE_FILE"
}

restart_service() {
  need_cmd rc-update
  need_cmd rc-service
  need_cmd xray
  ensure_openrc_service
  rc-update add "$XRAY_SVC" default >/dev/null 2>&1 || true
  if rc-service "$XRAY_SVC" status >/dev/null 2>&1; then
    rc-service "$XRAY_SVC" restart >/dev/null
  else
    rc-service "$XRAY_SVC" start >/dev/null
  fi
  rc-service "$XRAY_SVC" status >/dev/null 2>&1 || die "Service $XRAY_SVC is not active."
}

get_public_ip() {
  local ip=""
  ip="$(curl -4fsS https://api.ipify.org || true)"
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
  echo "Proxy endpoint: socks5h://${host}:${PORT}"
  echo "Test:"
  print_curl_test_cmd "$host" "$PORT" "$PROXY_USER" "$PROXY_PASS"
}

validate_runtime_values() {
  is_valid_port "$PORT" || die "Invalid port: $PORT"
  [[ -n "$PROXY_USER" ]] || die "Username is empty."
  [[ -n "$PROXY_PASS" ]] || die "Password is empty."
  [[ "$ENABLE_FIREWALL" == "0" || "$ENABLE_FIREWALL" == "1" ]] || die "ENABLE_FIREWALL must be 0 or 1."
  [[ "$ALLOW_UDP" == "0" || "$ALLOW_UDP" == "1" ]] || die "ALLOW_UDP must be 0 or 1."
}

prepare_install_values() {
  PORT="${PORT:-8888}"
  PROXY_USER="${PROXY_USER:-king}"
  PROXY_PASS="${PROXY_PASS:-$(gen_password)}"
  ENABLE_FIREWALL="${ENABLE_FIREWALL:-1}"
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
  ENABLE_FIREWALL="${ENABLE_FIREWALL:-${META_ENABLE_FIREWALL:-1}}"
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

  if [[ "${META_ENABLE_FIREWALL:-1}" == "1" ]]; then
    local old_port="${META_PORT:-${CURRENT_PORT:-$PORT}}"
    local old_ip="${META_ALLOW_IP:-}"
    local old_udp="${META_ALLOW_UDP:-1}"
    cleanup_firewall_rules "$old_port" "$old_ip" "$old_udp"
  fi
  apply_firewall_rules

  restart_service
  save_meta
  echo "Install/Apply completed."
  print_connection
}

cmd_update() {
  need_root
  ENABLE_FIREWALL="${ENABLE_FIREWALL:-1}"
  ensure_packages
  prepare_update_values
  validate_runtime_values

  local old_port old_ip old_udp old_enable
  old_port="${META_PORT:-$CURRENT_PORT}"
  old_ip="${META_ALLOW_IP:-}"
  old_udp="${META_ALLOW_UDP:-$(current_udp_to_flag)}"
  old_enable="${META_ENABLE_FIREWALL:-1}"

  install_xray_if_needed
  backup_config_if_exists
  write_config
  validate_config

  if [[ "$old_enable" == "1" ]]; then
    cleanup_firewall_rules "$old_port" "$old_ip" "$old_udp"
  fi
  apply_firewall_rules

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

  if [[ -f "$OPENRC_SERVICE_FILE" ]]; then
    rc-service "$XRAY_SVC" stop >/dev/null 2>&1 || true
    rc-update del "$XRAY_SVC" default >/dev/null 2>&1 || true
  fi

  if [[ "$REMOVE_FIREWALL_RULES" == "1" ]]; then
    cleanup_firewall_rules "$old_port" "$old_ip" "$old_udp"
  fi

  rm -f "$XRAY_CFG" "$META_FILE" "$OPENRC_SERVICE_FILE"

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
  echo "ENABLE_FIREWALL(meta): ${META_ENABLE_FIREWALL:-<not set>}"
}

cmd_status() {
  local active="inactive"
  if [[ -f "$OPENRC_SERVICE_FILE" ]]; then
    if rc-service "$XRAY_SVC" status >/dev/null 2>&1; then
      active="active"
    fi
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

  echo "Testing proxy: ${TEST_HOST}:${CURRENT_PORT}"
  curl --proxy "socks5h://${TEST_HOST}:${CURRENT_PORT}" \
    --proxy-user "${CURRENT_USER}:${CURRENT_PASS}" \
    -sS --connect-timeout 8 --max-time 20 "$TEST_URL"
  echo
  echo "Test succeeded."
}

menu_install() {
  read_current_config
  load_meta

  local default_port default_user default_allow default_fw default_udp
  default_port="${CURRENT_PORT:-8888}"
  default_user="${CURRENT_USER:-king}"
  default_allow="${META_ALLOW_IP:-}"
  default_fw="${META_ENABLE_FIREWALL:-1}"
  default_udp="${META_ALLOW_UDP:-$(current_udp_to_flag)}"

  echo ">>> Install/Reinstall SOCKS5"
  PORT="$(prompt_text "Port" "$default_port")"
  PROXY_USER="$(prompt_text "Username" "$default_user")"
  PROXY_PASS="$(prompt_password_optional "Password (empty = auto generate)")"
  ALLOW_IP="$(prompt_text "Allow source IP/CIDR (empty = no limit)" "$default_allow")"
  ENABLE_FIREWALL="$(prompt_yes_no "Enable firewall rules (iptables)" "$default_fw")"
  ALLOW_UDP="$(prompt_yes_no "Enable UDP" "$default_udp")"

  run_action_safe cmd_install || true
}

menu_update() {
  read_current_config
  load_meta

  if [[ ! -f "$XRAY_CFG" || -z "$CURRENT_PORT" || -z "$CURRENT_USER" || -z "$CURRENT_PASS" ]]; then
    echo "No existing SOCKS5 config found. Please install first."
    return 0
  fi

  local default_fw default_udp new_pass
  default_fw="${META_ENABLE_FIREWALL:-1}"
  default_udp="${META_ALLOW_UDP:-$(current_udp_to_flag)}"

  echo ">>> Update SOCKS5 config"
  PORT="$(prompt_text "Port" "$CURRENT_PORT")"
  PROXY_USER="$(prompt_text "Username" "$CURRENT_USER")"
  new_pass="$(prompt_password_optional "New password (empty = keep current)")"
  if [[ -n "$new_pass" ]]; then
    PROXY_PASS="$new_pass"
  else
    PROXY_PASS="$CURRENT_PASS"
  fi
  ALLOW_IP="$(prompt_text "Allow source IP/CIDR (empty = no limit)" "${META_ALLOW_IP:-}")"
  ENABLE_FIREWALL="$(prompt_yes_no "Enable firewall rules (iptables)" "$default_fw")"
  ALLOW_UDP="$(prompt_yes_no "Enable UDP" "$default_udp")"

  run_action_safe cmd_update || true
}

menu_remove() {
  read_current_config
  load_meta

  local default_port default_allow confirm
  default_port="${META_PORT:-${CURRENT_PORT:-8888}}"
  default_allow="${META_ALLOW_IP:-}"

  echo ">>> Remove SOCKS5 config"
  PORT="$(prompt_text "Port used for firewall cleanup" "$default_port")"
  ALLOW_IP="$(prompt_text "Old allowed source IP/CIDR (empty = no limit)" "$default_allow")"
  REMOVE_FIREWALL_RULES="$(prompt_yes_no "Remove firewall rules" "1")"
  PURGE_XRAY="$(prompt_yes_no "Purge Xray binaries" "0")"
  confirm="$(prompt_yes_no "Confirm remove action" "0")"
  if [[ "$confirm" != "1" ]]; then
    echo "Canceled."
    return 0
  fi

  run_action_safe cmd_remove || true
}

menu_test() {
  echo ">>> Test SOCKS5"
  TEST_HOST="$(prompt_text "Test host (usually 127.0.0.1)" "$TEST_HOST")"
  TEST_URL="$(prompt_text "Test URL" "$TEST_URL")"
  run_action_safe cmd_test || true
}

cmd_menu() {
  if [[ ! -t 0 ]]; then
    usage
    return 0
  fi

  while true; do
    echo
    echo "===== SOCKS5 Manager ====="
    echo "1) Install/Reinstall"
    echo "2) Update"
    echo "3) Show Config"
    echo "4) Status"
    echo "5) Test Proxy"
    echo "6) Remove"
    echo "0) Exit"
    read -r -p "Choose [0-6]: " choice || true

    case "${choice:-}" in
    1) menu_install ;;
    2) menu_update ;;
    3) run_action_safe cmd_show || true ;;
    4) run_action_safe cmd_status || true ;;
    5) menu_test ;;
    6) menu_remove ;;
    0)
      echo "Bye."
      return 0
      ;;
    *)
      echo "Invalid choice. Please enter 0-6."
      ;;
    esac
  done
}

parse_args "$@"

case "$ACTION" in
menu) cmd_menu ;;
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
