#!/usr/bin/env bash
set -Eeuo pipefail

readonly HYSTERIA_API_URL="https://api.github.com/repos/apernet/hysteria/releases/latest"
readonly BIN_PATH="/usr/local/bin/hysteria"
readonly CONFIG_DIR="/etc/hysteria"
readonly SERVER_CONFIG="$CONFIG_DIR/config.yaml"
readonly CLIENT_CONFIG="$CONFIG_DIR/client.yaml"
readonly SERVICE_PATH="/etc/systemd/system/hysteria-server.service"
readonly SERVICE_NAME="hysteria-server"
readonly DEFAULT_PORT="443"
readonly DEFAULT_MASQUERADE_URL="https://news.ycombinator.com/"

TMP_DIR=""

log() {
  printf '[INFO] %s\n' "$*" >&2
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
    rm -rf "$TMP_DIR"
  fi
}

trap cleanup EXIT

show_help() {
  cat <<'EOF'
Usage:
  bash install.sh             Install Hysteria 2 server
  bash install.sh install     Install Hysteria 2 server
  bash install.sh update      Update /usr/local/bin/hysteria only
  bash install.sh --help      Show this help

Install mode writes:
  /usr/local/bin/hysteria
  /etc/hysteria/config.yaml
  /etc/hysteria/client.yaml
  /etc/systemd/system/hysteria-server.service

Update mode preserves all config, certificate, and systemd files.
EOF
}

validate_port() {
  local port="${1:-}"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  ((port >= 1 && port <= 65535))
}

yaml_quote() {
  local value="${1:-}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

normalize_version() {
  local input="${1:-}"
  if [[ "$input" =~ app/v[0-9][A-Za-z0-9._+/-]* ]]; then
    printf '%s\n' "${BASH_REMATCH[0]}"
  elif [[ "$input" =~ v[0-9][A-Za-z0-9._+-]* ]]; then
    printf '%s\n' "${BASH_REMATCH[0]}"
  else
    printf '%s\n' "$input"
  fi
}

version_equal() {
  local left="${1:-}"
  local right="${2:-}"
  left="${left#app/}"
  right="${right#app/}"
  [[ -n "$left" && "$left" == "$right" ]]
}

map_arch() {
  local machine="${1:-}"
  local flags="${2:-}"

  case "$machine" in
    x86_64 | amd64)
      if [[ " $flags " == *" avx "* ]]; then
        printf 'amd64-avx\n'
      else
        printf 'amd64\n'
      fi
      ;;
    i386 | i486 | i586 | i686)
      printf '386\n'
      ;;
    aarch64 | arm64)
      printf 'arm64\n'
      ;;
    armv5*)
      printf 'armv5\n'
      ;;
    armv6* | armv7* | arm*)
      printf 'arm\n'
      ;;
    riscv64)
      printf 'riscv64\n'
      ;;
    s390x)
      printf 's390x\n'
      ;;
    loongarch64 | loong64)
      printf 'loong64\n'
      ;;
    mipsle | mipsel)
      printf 'mipsle\n'
      ;;
    *)
      return 1
      ;;
  esac
}

detect_arch() {
  local machine flags
  machine="$(uname -m)"
  flags=""
  if [[ -r /proc/cpuinfo ]]; then
    flags="$(tr '\n' ' ' </proc/cpuinfo)"
  fi
  map_arch "$machine" "$flags" || die "Unsupported CPU architecture: $machine"
}

extract_tag_name() {
  local json="$1"
  printf '%s\n' "$json" |
    sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
    head -n 1
}

extract_asset_url() {
  local json="$1"
  local asset_name="$2"
  printf '%s\n' "$json" |
    sed 's/},{/}\
{/g' |
    awk -v name="$asset_name" '
      index($0, "\"name\":\"" name "\"") || index($0, "\"name\": \"" name "\"") { found=1 }
      found && index($0, "\"browser_download_url\"") {
        sub(/^.*"browser_download_url"[[:space:]]*:[[:space:]]*"/, "")
        sub(/".*$/, "")
        print
        exit
      }
    '
}

extract_sha256() {
  local hashes="$1"
  local asset_name="$2"
  printf '%s\n' "$hashes" |
    awk -v name="$asset_name" '
      {
        file=$2
        gsub(/^.*\//, "", file)
        if (file == name && length($1) == 64 && $1 ~ /^[0-9a-fA-F]+$/) {
          print tolower($1)
          exit
        }
      }
    '
}

format_host_port() {
  local host="$1"
  local port="$2"
  if [[ "$host" == \[*\] ]]; then
    printf '%s:%s\n' "$host" "$port"
  elif [[ "$host" == *:* ]]; then
    printf '[%s]:%s\n' "$host" "$port"
  else
    printf '%s:%s\n' "$host" "$port"
  fi
}

render_server_config() {
  local port="$1"
  local auth_password="$2"
  local tls_mode="$3"
  local tls_host="$4"
  local acme_email="$5"
  local cert_path="${6:-}"
  local key_path="${7:-}"
  local obfs_password="${8:-}"
  local masquerade_url="${9:-}"

  cat <<EOF
listen: :$port

auth:
  type: password
  password: $(yaml_quote "$auth_password")
EOF

  case "$tls_mode" in
    acme)
      cat <<EOF

acme:
  domains:
    - $(yaml_quote "$tls_host")
  email: $(yaml_quote "$acme_email")
EOF
      ;;
    selfsigned)
      cat <<EOF

tls:
  cert: $(yaml_quote "$cert_path")
  key: $(yaml_quote "$key_path")
EOF
      ;;
    *)
      return 1
      ;;
  esac

  if [[ -n "$obfs_password" ]]; then
    cat <<EOF

obfs:
  type: salamander
  salamander:
    password: $(yaml_quote "$obfs_password")
EOF
  fi

  if [[ -n "$masquerade_url" ]]; then
    cat <<EOF

masquerade:
  type: proxy
  proxy:
    url: $(yaml_quote "$masquerade_url")
    rewriteHost: true
EOF
  fi
}

render_client_config() {
  local server_host="$1"
  local port="$2"
  local auth_password="$3"
  local tls_mode="$4"
  local sni="${5:-}"
  local ca_path="${6:-}"
  local pin_sha256="${7:-}"
  local obfs_password="${8:-}"
  local server_address

  server_address="$(format_host_port "$server_host" "$port")"

  cat <<EOF
server: $server_address
auth: $(yaml_quote "$auth_password")
EOF

  if [[ "$tls_mode" == "selfsigned" ]]; then
    cat <<EOF

tls:
  sni: $(yaml_quote "${sni:-$server_host}")
EOF
    if [[ -n "$pin_sha256" ]]; then
      printf '  pinSHA256: %s\n' "$(yaml_quote "$pin_sha256")"
    fi
    if [[ -n "$ca_path" ]]; then
      printf '  ca: %s\n' "$(yaml_quote "$ca_path")"
    fi
  fi

  if [[ -n "$obfs_password" ]]; then
    cat <<EOF

obfs:
  type: salamander
  salamander:
    password: $(yaml_quote "$obfs_password")
EOF
  fi
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "This command must be run as root. Try: sudo bash install.sh"
  fi
}

require_linux_systemd() {
  [[ "$(uname -s)" == "Linux" ]] || die "This installer only supports Linux."
  command -v systemctl >/dev/null 2>&1 || die "systemctl not found. systemd is required."
  [[ -d /run/systemd/system || -d /etc/systemd/system ]] || die "systemd directories not found."
}

missing_commands() {
  local missing=()
  local cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done
  printf '%s\n' "${missing[@]}"
}

prompt_default() {
  local prompt="$1"
  local default="$2"
  local value
  read -r -p "$prompt [$default]: " value
  printf '%s\n' "${value:-$default}"
}

prompt_required() {
  local prompt="$1"
  local value
  while true; do
    read -r -p "$prompt: " value
    if [[ -n "$value" ]]; then
      printf '%s\n' "$value"
      return 0
    fi
    warn "Value cannot be empty."
  done
}

prompt_secret_or_generate() {
  local prompt="$1"
  local value
  read -r -s -p "$prompt (leave empty to auto-generate): " value
  printf '\n' >&2
  if [[ -z "$value" ]]; then
    openssl rand -base64 32
  else
    printf '%s\n' "$value"
  fi
}

prompt_yes_no() {
  local prompt="$1"
  local default="${2:-N}"
  local suffix value

  case "$default" in
    Y | y) suffix="Y/n" ;;
    *) suffix="y/N" ;;
  esac

  while true; do
    read -r -p "$prompt [$suffix]: " value
    value="${value:-$default}"
    case "$value" in
      Y | y | yes | YES) return 0 ;;
      N | n | no | NO) return 1 ;;
      *) warn "Please answer yes or no." ;;
    esac
  done
}

ensure_dependencies() {
  local required=(curl openssl awk sed grep chmod install mktemp sha256sum)
  local missing=()
  local cmd
  while IFS= read -r cmd; do
    [[ -n "$cmd" ]] && missing+=("$cmd")
  done < <(missing_commands "${required[@]}")

  if ((${#missing[@]} == 0)); then
    return 0
  fi

  warn "Missing required commands: ${missing[*]}"
  if ! prompt_yes_no "Try to install missing dependencies with the system package manager?" "Y"; then
    die "Install the missing commands and rerun this script."
  fi

  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y curl ca-certificates openssl coreutils gawk sed grep
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl ca-certificates openssl coreutils gawk sed grep
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl ca-certificates openssl coreutils gawk sed grep
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm curl ca-certificates openssl coreutils gawk sed grep
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install curl ca-certificates openssl coreutils gawk sed grep
  else
    die "No supported package manager found. Install: ${missing[*]}"
  fi

  missing=()
  while IFS= read -r cmd; do
    [[ -n "$cmd" ]] && missing+=("$cmd")
  done < <(missing_commands "${required[@]}")
  ((${#missing[@]} == 0)) || die "Still missing commands after dependency install: ${missing[*]}"
}

fetch_latest_release_json() {
  curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    -H "User-Agent: hysteria2-1click-installer" \
    "$HYSTERIA_API_URL"
}

prepare_tmp_dir() {
  TMP_DIR="$(mktemp -d)"
}

verify_sha256() {
  local file="$1"
  local expected="$2"
  local actual
  actual="$(sha256sum "$file" | awk '{print tolower($1)}')"
  [[ "$actual" == "$expected" ]] || die "SHA256 mismatch for $(basename "$file")."
}

download_latest_binary() {
  local arch="$1"
  local output_path="$2"
  local release_json tag asset_name asset_url hashes_url hashes expected_hash

  release_json="$(fetch_latest_release_json)"
  tag="$(extract_tag_name "$release_json")"
  [[ -n "$tag" ]] || die "Could not parse latest release tag from GitHub API."

  asset_name="hysteria-linux-$arch"
  asset_url="$(extract_asset_url "$release_json" "$asset_name")"
  [[ -n "$asset_url" ]] || die "Could not find release asset: $asset_name"

  log "Latest Hysteria release: $tag"
  log "Downloading $asset_name"
  curl -fL --retry 3 --retry-delay 2 -o "$output_path" "$asset_url"

  hashes_url="$(extract_asset_url "$release_json" "hashes.txt" || true)"
  if [[ -n "$hashes_url" ]]; then
    hashes="$(curl -fsSL "$hashes_url")"
    expected_hash="$(extract_sha256 "$hashes" "$asset_name")"
    if [[ -n "$expected_hash" ]]; then
      verify_sha256 "$output_path" "$expected_hash"
      log "SHA256 verified."
    else
      warn "hashes.txt did not contain $asset_name; skipping checksum verification."
    fi
  else
    warn "hashes.txt was not found in the release; skipping checksum verification."
  fi

  chmod 0755 "$output_path"
  printf '%s\n' "$tag"
}

installed_version() {
  if [[ ! -x "$BIN_PATH" ]]; then
    return 1
  fi
  normalize_version "$("$BIN_PATH" version 2>/dev/null || true)"
}

install_binary_from_latest() {
  local arch binary tag
  arch="$(detect_arch)"
  prepare_tmp_dir
  binary="$TMP_DIR/hysteria"
  tag="$(download_latest_binary "$arch" "$binary")"
  install -m 0755 "$binary" "$BIN_PATH"
  "$BIN_PATH" version >/dev/null 2>&1 || die "Installed hysteria binary failed version check."
  log "Installed Hysteria $tag to $BIN_PATH"
}

backup_config_dir() {
  if [[ ! -d "$CONFIG_DIR" ]]; then
    return 0
  fi

  local backup_dir
  backup_dir="$CONFIG_DIR/backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup_dir"

  local item
  for item in config.yaml client.yaml server.crt server.key; do
    if [[ -e "$CONFIG_DIR/$item" ]]; then
      cp -a "$CONFIG_DIR/$item" "$backup_dir/"
    fi
  done
  chmod 700 "$backup_dir"
  log "Existing config files backed up to $backup_dir"
}

create_self_signed_cert() {
  local host="$1"
  local cert_path="$2"
  local key_path="$3"
  local san_type="DNS"

  if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || "$host" == *:* ]]; then
    san_type="IP"
  fi

  openssl req -x509 -newkey rsa:3072 -sha256 -days 825 -nodes \
    -keyout "$key_path" \
    -out "$cert_path" \
    -subj "/CN=$host" \
    -addext "subjectAltName=$san_type:$host"
  chmod 600 "$cert_path" "$key_path"
}

cert_fingerprint_sha256() {
  local cert_path="$1"
  openssl x509 -noout -fingerprint -sha256 -in "$cert_path" | awk -F= '{print $2}'
}

write_server_config() {
  local port="$1"
  local auth_password="$2"
  local tls_mode="$3"
  local tls_host="$4"
  local acme_email="$5"
  local cert_path="$6"
  local key_path="$7"
  local obfs_password="$8"
  local masquerade_url="$9"

  render_server_config \
    "$port" \
    "$auth_password" \
    "$tls_mode" \
    "$tls_host" \
    "$acme_email" \
    "$cert_path" \
    "$key_path" \
    "$obfs_password" \
    "$masquerade_url" >"$SERVER_CONFIG"
  chmod 600 "$SERVER_CONFIG"
}

write_client_config() {
  local host="$1"
  local port="$2"
  local auth_password="$3"
  local tls_mode="$4"
  local ca_path="$5"
  local pin_sha256="$6"
  local obfs_password="$7"

  render_client_config \
    "$host" \
    "$port" \
    "$auth_password" \
    "$tls_mode" \
    "$host" \
    "$ca_path" \
    "$pin_sha256" \
    "$obfs_password" >"$CLIENT_CONFIG"
  chmod 600 "$CLIENT_CONFIG"
}

write_systemd_service() {
  cat >"$SERVICE_PATH" <<EOF
[Unit]
Description=Hysteria 2 Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN_PATH server -c $SERVER_CONFIG
Restart=on-failure
RestartSec=5s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$SERVICE_PATH"
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME"
}

restart_service_or_show_logs() {
  if ! systemctl restart "$SERVICE_NAME"; then
    warn "Failed to restart $SERVICE_NAME."
    warn "Run this for details: journalctl -u $SERVICE_NAME -n 80 --no-pager"
    return 1
  fi
  systemctl is-active --quiet "$SERVICE_NAME"
}

configure_firewall() {
  local port="$1"
  local changed=0

  if command -v ufw >/dev/null 2>&1; then
    if prompt_yes_no "ufw detected. Allow UDP $port through ufw?" "Y"; then
      ufw allow "$port/udp"
      changed=1
    fi
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    if prompt_yes_no "firewalld detected. Allow UDP $port through firewalld?" "Y"; then
      firewall-cmd --permanent --add-port="$port/udp"
      firewall-cmd --reload
      changed=1
    fi
  fi

  return "$changed"
}

handle_existing_install() {
  local choice
  if [[ ! -e "$SERVER_CONFIG" ]]; then
    return 0
  fi

  warn "$SERVER_CONFIG already exists."
  while true; do
    read -r -p "Choose: reinstall and overwrite [r], update binary only [u], exit [e] (default e): " choice
    choice="${choice:-e}"
    case "$choice" in
      r | R) return 0 ;;
      u | U) update_flow; exit 0 ;;
      e | E) exit 0 ;;
      *) warn "Please enter r, u, or e." ;;
    esac
  done
}

prompt_port() {
  local port
  while true; do
    port="$(prompt_default "UDP listen port" "$DEFAULT_PORT")"
    if validate_port "$port"; then
      printf '%s\n' "$port"
      return 0
    fi
    warn "Invalid port: $port"
  done
}

prompt_tls_mode() {
  local choice
  while true; do
    read -r -p "TLS mode: ACME recommended [1], self-signed [2] (default 1): " choice
    choice="${choice:-1}"
    case "$choice" in
      1 | a | A | acme | ACME)
        printf 'acme\n'
        return 0
        ;;
      2 | s | S | self | selfsigned)
        printf 'selfsigned\n'
        return 0
        ;;
      *)
        warn "Please choose 1 or 2."
        ;;
    esac
  done
}

install_flow() {
  require_root
  require_linux_systemd
  ensure_dependencies
  handle_existing_install

  local port tls_mode tls_host acme_email auth_password obfs_password masquerade_url
  local cert_path key_path pin_sha256 ca_path firewall_changed

  install_binary_from_latest

  mkdir -p "$CONFIG_DIR"
  chmod 700 "$CONFIG_DIR"
  backup_config_dir

  port="$(prompt_port)"
  tls_mode="$(prompt_tls_mode)"
  acme_email=""
  cert_path=""
  key_path=""
  pin_sha256=""
  ca_path=""

  if [[ "$tls_mode" == "acme" ]]; then
    tls_host="$(prompt_required "Domain for ACME certificate")"
    acme_email="$(prompt_required "ACME email")"
  else
    tls_host="$(prompt_required "Host/domain/IP clients will connect to")"
    cert_path="$CONFIG_DIR/server.crt"
    key_path="$CONFIG_DIR/server.key"
    create_self_signed_cert "$tls_host" "$cert_path" "$key_path"
    pin_sha256="$(cert_fingerprint_sha256 "$cert_path")"
    ca_path="$cert_path"
  fi

  auth_password="$(prompt_secret_or_generate "Hysteria auth password")"

  obfs_password=""
  if prompt_yes_no "Enable obfs Salamander? Standard HTTP/3 masquerade will no longer work when enabled." "N"; then
    obfs_password="$(prompt_secret_or_generate "obfs Salamander password")"
  fi

  masquerade_url=""
  if [[ -n "$obfs_password" ]]; then
    warn "Masquerade is skipped because obfs disables standard HTTP/3 compatibility."
  else
    read -r -p "Masquerade proxy URL [$DEFAULT_MASQUERADE_URL, enter none to disable]: " masquerade_url
  fi
  if [[ -z "$masquerade_url" && -z "$obfs_password" ]]; then
    masquerade_url="$DEFAULT_MASQUERADE_URL"
  elif [[ "$masquerade_url" == "none" || "$masquerade_url" == "disable" ]]; then
    masquerade_url=""
  fi

  write_server_config \
    "$port" \
    "$auth_password" \
    "$tls_mode" \
    "$tls_host" \
    "$acme_email" \
    "$cert_path" \
    "$key_path" \
    "$obfs_password" \
    "$masquerade_url"

  write_client_config \
    "$tls_host" \
    "$port" \
    "$auth_password" \
    "$tls_mode" \
    "$ca_path" \
    "$pin_sha256" \
    "$obfs_password"

  firewall_changed=0
  configure_firewall "$port" || firewall_changed=1

  write_systemd_service
  restart_service_or_show_logs || die "Service restart failed."

  print_install_summary \
    "$tls_host" \
    "$port" \
    "$tls_mode" \
    "$auth_password" \
    "$obfs_password" \
    "$masquerade_url" \
    "$pin_sha256" \
    "$firewall_changed"
}

print_install_summary() {
  local host="$1"
  local port="$2"
  local tls_mode="$3"
  local auth_password="$4"
  local obfs_password="$5"
  local masquerade_url="$6"
  local pin_sha256="$7"
  local firewall_changed="$8"

  cat <<EOF

Hysteria 2 server installed.

Server: $host:$port
TLS mode: $tls_mode
Auth password: $auth_password
Server config: $SERVER_CONFIG
Client config: $CLIENT_CONFIG
Service: $SERVICE_NAME
Local firewall changed: $firewall_changed
Masquerade URL: ${masquerade_url:-disabled}
EOF

  if [[ -n "$obfs_password" ]]; then
    printf 'obfs Salamander password: %s\n' "$obfs_password"
  else
    printf 'obfs: disabled\n'
  fi

  if [[ -n "$pin_sha256" ]]; then
    printf 'Self-signed certificate SHA256 pin: %s\n' "$pin_sha256"
    printf 'Copy %s to clients if you prefer tls.ca verification.\n' "$CONFIG_DIR/server.crt"
  fi

  cat <<EOF

Next checks:
  systemctl status $SERVICE_NAME --no-pager
  journalctl -u $SERVICE_NAME -n 80 --no-pager

Cloud firewall reminder:
  Open UDP $port in your cloud provider security group.
EOF

  if [[ "$tls_mode" == "acme" ]]; then
    cat <<EOF
  ACME needs TCP 80/443 reachable from the public internet for certificate issuance.
EOF
  fi
}

rollback_binary() {
  local backup="$1"
  if [[ -f "$backup" ]]; then
    install -m 0755 "$backup" "$BIN_PATH"
    warn "Rolled back to $backup"
  fi
}

restart_service_if_present() {
  if systemctl list-unit-files --no-legend "$SERVICE_NAME.service" 2>/dev/null |
    grep -q "^$SERVICE_NAME.service"; then
    restart_service_or_show_logs
  fi
}

update_flow() {
  require_root
  require_linux_systemd
  ensure_dependencies

  [[ -x "$BIN_PATH" ]] || die "$BIN_PATH is not installed. Run: bash install.sh install"

  local arch release_json latest_tag current_version asset_name asset_url binary backup
  local hashes_url hashes expected_hash
  arch="$(detect_arch)"
  release_json="$(fetch_latest_release_json)"
  latest_tag="$(extract_tag_name "$release_json")"
  [[ -n "$latest_tag" ]] || die "Could not parse latest release tag from GitHub API."

  current_version="$(installed_version || true)"
  if version_equal "$current_version" "$latest_tag"; then
    log "Hysteria is already up to date: $latest_tag"
    return 0
  fi

  asset_name="hysteria-linux-$arch"
  asset_url="$(extract_asset_url "$release_json" "$asset_name")"
  [[ -n "$asset_url" ]] || die "Could not find release asset: $asset_name"

  prepare_tmp_dir
  binary="$TMP_DIR/hysteria"
  curl -fL --retry 3 --retry-delay 2 -o "$binary" "$asset_url"

  hashes_url="$(extract_asset_url "$release_json" "hashes.txt" || true)"
  if [[ -n "$hashes_url" ]]; then
    hashes="$(curl -fsSL "$hashes_url")"
    expected_hash="$(extract_sha256 "$hashes" "$asset_name")"
    if [[ -n "$expected_hash" ]]; then
      verify_sha256 "$binary" "$expected_hash"
    else
      warn "hashes.txt did not contain $asset_name; skipping checksum verification."
    fi
  fi

  chmod 0755 "$binary"
  backup="$BIN_PATH.bak.$(date +%Y%m%d-%H%M%S)"
  cp -a "$BIN_PATH" "$backup"

  if ! install -m 0755 "$binary" "$BIN_PATH"; then
    rollback_binary "$backup"
    die "Failed to install updated binary."
  fi

  if ! "$BIN_PATH" version >/dev/null 2>&1; then
    rollback_binary "$backup"
    die "Updated binary failed version check."
  fi

  if ! restart_service_if_present; then
    rollback_binary "$backup"
    restart_service_if_present || true
    die "Updated binary caused service restart failure; rollback attempted."
  fi

  log "Updated Hysteria from ${current_version:-unknown} to $latest_tag"
  log "Previous binary backup: $backup"
}

main() {
  # When run via `curl ... | bash`, stdin is the script text itself, so the
  # interactive prompts below cannot read the user's answers. Reattach stdin to
  # the controlling terminal when one is available. Skipped when stdin is
  # already a terminal (e.g. `bash install.sh` or `bash <(curl ...)`).
  if [[ ! -t 0 ]] && { : </dev/tty; } 2>/dev/null; then
    exec </dev/tty
  fi

  local command="${1:-install}"
  case "$command" in
    install)
      install_flow
      ;;
    update)
      update_flow
      ;;
    -h | --help | help)
      show_help
      ;;
    *)
      show_help >&2
      die "Unknown command: $command"
      ;;
  esac
}

# Run main when the script is executed directly (including `curl ... | bash`),
# but not when it is sourced (e.g. by the test suite).
if ! (return 0 2>/dev/null); then
  main "$@"
fi
