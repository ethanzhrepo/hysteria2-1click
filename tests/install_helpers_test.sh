#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/install.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  [[ "$actual" == "$expected" ]] || fail "$label: expected [$expected], got [$actual]"
}

assert_ok() {
  local label="$1"
  shift
  "$@" || fail "$label"
}

assert_fail() {
  local label="$1"
  shift
  if "$@"; then
    fail "$label unexpectedly passed"
  fi
}

test_validate_port() {
  assert_ok "443 is valid" validate_port 443
  assert_ok "65535 is valid" validate_port 65535
  assert_fail "0 is invalid" validate_port 0
  assert_fail "65536 is invalid" validate_port 65536
  assert_fail "abc is invalid" validate_port abc
}

test_yaml_quote() {
  assert_eq '"simple"' "$(yaml_quote "simple")" "quotes simple string"
  assert_eq '"a\"b\\c"' "$(yaml_quote 'a"b\c')" "escapes quote and slash"
}

test_normalize_version() {
  assert_eq "app/v2.9.2" "$(normalize_version "Version: app/v2.9.2")" "extracts app version"
  assert_eq "v2.9.2" "$(normalize_version "v2.9.2")" "keeps plain semver tag"
}

test_arch_mapping() {
  assert_eq "amd64" "$(map_arch x86_64 "")" "maps x86_64 without avx"
  assert_eq "amd64-avx" "$(map_arch x86_64 "avx sse4_2")" "maps x86_64 with avx"
  assert_eq "arm64" "$(map_arch aarch64 "")" "maps aarch64"
  assert_eq "arm" "$(map_arch armv7l "")" "maps armv7"
  assert_eq "386" "$(map_arch i686 "")" "maps i686"
}

test_release_parsing() {
  local json='{"tag_name":"app/v2.9.2","assets":[{"name":"hysteria-linux-amd64","browser_download_url":"https://example.invalid/hysteria-linux-amd64"},{"name":"hashes.txt","browser_download_url":"https://example.invalid/hashes.txt"}]}'
  assert_eq "app/v2.9.2" "$(extract_tag_name "$json")" "extracts tag"
  assert_eq "https://example.invalid/hysteria-linux-amd64" "$(extract_asset_url "$json" "hysteria-linux-amd64")" "extracts asset url"
  assert_eq "https://example.invalid/hashes.txt" "$(extract_asset_url "$json" "hashes.txt")" "extracts hashes url"
}

test_hash_parsing() {
  local hashes='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  hysteria-linux-amd64'
  assert_eq "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$(extract_sha256 "$hashes" "hysteria-linux-amd64")" "extracts sha256"
}

test_config_generation() {
  local cfg
  assert_eq "example.com:443" "$(format_host_port "example.com" 443)" "formats domain host"
  assert_eq "[2001:db8::1]:443" "$(format_host_port "2001:db8::1" 443)" "formats IPv6 host"

  cfg="$(render_server_config 443 "password value" "acme" "example.com" "admin@example.com" "" "" "" "https://news.ycombinator.com/")"
  [[ "$cfg" == *"listen: :443"* ]] || fail "server config has listen"
  [[ "$cfg" == *'password: "password value"'* ]] || fail "server config has quoted password"
  [[ "$cfg" == *"acme:"* ]] || fail "server config has acme"
  [[ "$cfg" == *"masquerade:"* ]] || fail "server config has masquerade"

  cfg="$(render_client_config "example.com" 443 "password value" "acme" "" "" "" "")"
  [[ "$cfg" == *"server: example.com:443"* ]] || fail "client config has server"
  [[ "$cfg" == *'auth: "password value"'* ]] || fail "client config has auth"
}

main() {
  test_validate_port
  test_yaml_quote
  test_normalize_version
  test_arch_mapping
  test_release_parsing
  test_hash_parsing
  test_config_generation
  printf 'All helper tests passed\n'
}

main "$@"
