# Hysteria2 Install Script Design

## Goal

Build a single-file `install.sh` that installs and updates Hysteria 2 on Linux systemd servers. The script must always fetch the current latest upstream release at runtime, generate a best-practice server configuration through interactive prompts, and support both initial installation and program-only updates.

## Scope

The script targets Linux VPS/server environments that use systemd. It does not target Docker, OpenWrt, macOS service installation, or non-systemd init systems.

The script supports:

- `bash install.sh` as a default alias for `install`
- `bash install.sh install`
- `bash install.sh update`
- `bash install.sh --help`

The implementation is a pure Bash script. It depends on common system tools such as `curl`, `openssl`, `systemctl`, and archive utilities. If required commands are missing, the script either installs base dependencies through the detected package manager or exits with a clear error.

## Upstream Sources

The script does not hard-code a Hysteria version. It queries the GitHub latest release endpoint at runtime and downloads the matching Linux asset for the detected CPU architecture.

Reference sources:

- Hysteria 2 installation documentation: `https://v2.hysteria.network/docs/getting-started/Installation/`
- Hysteria 2 server documentation: `https://v2.hysteria.network/docs/getting-started/Server/`
- Hysteria 2 releases: `https://github.com/apernet/hysteria/releases/latest`
- GitHub latest release API: `https://api.github.com/repos/apernet/hysteria/releases/latest`

Before implementation, client configuration field names for self-signed certificate handling must be verified against current Hysteria 2 documentation.

## Architecture

`install.sh` is organized into focused Bash functions:

- Entry dispatch: parse `install`, `update`, and `--help`.
- Environment checks: verify root, Linux, systemd, dependencies, and supported architecture.
- Release discovery: query GitHub latest release API and select the right Linux asset.
- Binary install/update: download into a temporary directory, extract if needed, install to `/usr/local/bin/hysteria`, and make executable.
- Interactive configuration: prompt for TLS mode, port, auth password, optional obfs, and firewall handling.
- Server config generation: write `/etc/hysteria/config.yaml`.
- Client config generation: write `/etc/hysteria/client.yaml`.
- systemd setup: write `/etc/systemd/system/hysteria-server.service`, reload daemon, enable, and restart.
- Firewall handling: optionally open the configured UDP port for `ufw` or `firewalld`.
- Result reporting: print service status, connection parameters, and cloud security group reminders.

Temporary files are created with `mktemp -d` and removed on exit.

## Install Flow

The default install command performs these steps:

1. Check the runtime environment.
2. Detect the local CPU architecture and map it to the upstream Hysteria Linux asset.
3. Query GitHub for the latest Hysteria release.
4. Download and install the Hysteria binary.
5. Prompt for the listen UDP port, defaulting to `443`.
6. Prompt for TLS mode:
   - ACME, recommended by default.
   - Self-signed certificate fallback.
7. Prompt for authentication password:
   - Read with hidden input.
   - If left empty, generate a strong random password with `openssl rand -base64 32`.
8. Prompt for optional obfs:
   - Default disabled.
   - If enabled, use Salamander.
   - Read the obfs password with hidden input or auto-generate one if left empty.
9. If obfs is disabled, prompt for an HTTP/3 masquerade proxy URL, defaulting to `https://news.ycombinator.com/`; `none` or `disable` disables masquerade. If obfs is enabled, skip masquerade because obfs disables standard HTTP/3 compatibility.
10. Prompt to configure local firewall rules when `ufw` or `firewalld` is detected.
11. Back up existing `/etc/hysteria` configuration if present.
12. Write server and client configuration files with restrictive permissions.
13. Install and start the systemd service.
14. Print a concise install summary and follow-up reminders.

If `/etc/hysteria/config.yaml` already exists, the script asks whether to overwrite and reinstall, run update only, or exit.

## Configuration Model

The Hysteria server listens on the configured UDP port:

```yaml
listen: :443
```

Authentication uses password auth:

```yaml
auth:
  type: password
  password: "<generated-or-entered-password>"
```

ACME mode writes:

```yaml
acme:
  domains:
    - example.com
  email: admin@example.com
```

Self-signed mode writes certificate files under `/etc/hysteria`:

```yaml
tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key
```

Optional obfs uses Salamander:

```yaml
obfs:
  type: salamander
  salamander:
    password: "<generated-or-entered-obfs-password>"
```

By default, the script enables HTTP/3 masquerade with a configurable proxy target:

```yaml
masquerade:
  type: proxy
  proxy:
    url: https://news.ycombinator.com/
    rewriteHost: true
```

`/etc/hysteria` is set to mode `700`. Configuration files and private keys are set to mode `600`.

## Client Config Output

The script writes `/etc/hysteria/client.yaml` for operator convenience.

For ACME mode, the client server address uses the configured domain and port.

For self-signed mode, the client config includes the entered host and certificate handling fields verified against current Hysteria 2 client documentation. The install summary must clearly distinguish between importing the generated certificate and any insecure verification option.

The install summary prints:

- Server address
- UDP port
- Auth password
- obfs status and password when enabled
- TLS mode
- Paths to server and client configuration files
- Local firewall changes if applied
- Reminder to open the UDP port in the cloud provider security group
- ACME reminder that TCP `80` and `443` must be reachable for certificate issuance

## Update Flow

`bash install.sh update` updates only `/usr/local/bin/hysteria`.

It performs these steps:

1. Verify Hysteria is already installed.
2. Query the GitHub latest release endpoint.
3. Compare the installed version with the latest release where possible.
4. If already current, exit without changes.
5. Download the matching latest binary to a temporary directory.
6. Back up the existing binary to `/usr/local/bin/hysteria.bak.<timestamp>`.
7. Replace `/usr/local/bin/hysteria`.
8. Run `/usr/local/bin/hysteria version` to verify the new binary.
9. Restart `hysteria-server` when the service exists.
10. If verification or restart fails, restore the previous binary and restart the service again.

The update flow never changes `/etc/hysteria/config.yaml`, `/etc/hysteria/client.yaml`, certificates, keys, or the systemd unit unless a future explicit migration is added.

## Error Handling

The script uses `set -Eeuo pipefail` and exits on unexpected failures.

Clear errors are shown for:

- Non-root execution.
- Non-Linux OS.
- Missing systemd.
- Unsupported CPU architecture.
- Missing required commands when dependency installation is unavailable or declined.
- GitHub API failure.
- Missing matching release asset.
- Download, extraction, or install failure.
- Invalid port input.
- Empty required ACME domain or email.
- systemd restart failure.

When service restart fails, the script prints a command the user can run:

```bash
journalctl -u hysteria-server -n 80 --no-pager
```

## Verification

Local verification before release:

- `bash -n install.sh`
- `shellcheck install.sh` when `shellcheck` is installed
- `bash install.sh --help`
- Non-root install attempt must fail with a clear message
- `bash install.sh update` with no existing installation must fail with a clear message

Target VPS verification:

- Install with ACME mode on a domain whose DNS points to the server.
- Install with self-signed mode on a test server.
- Confirm `systemctl status hysteria-server` reports active.
- Confirm `/etc/hysteria/config.yaml` and `/etc/hysteria/client.yaml` are written with mode `600`.
- Confirm update preserves existing configuration and rolls back if service restart fails.

## Out of Scope

- Docker deployment.
- OpenWrt package installation.
- Non-systemd service managers.
- Cloud provider security group API automation.
- Multi-user auth management.
- Client installation on local devices.
- Traffic shaping, bandwidth policy, and advanced routing configuration.
