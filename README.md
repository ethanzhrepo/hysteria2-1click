# Hysteria2 One-Click Installer

This project provides a single Bash script for installing and updating a Hysteria 2 server on Linux systemd VPS hosts.

The script fetches the latest upstream release from GitHub at runtime. It does not hard-code a Hysteria version.

## Quick Install (remote one-liner)

Run directly from GitHub on your VPS. The installer is interactive (it asks for
port, TLS mode, domain, etc.), and it automatically reattaches input to your
terminal, so the prompts work even through a pipe:

```bash
curl -fsSL https://raw.githubusercontent.com/ethanzhrepo/hysteria2-1click/main/install.sh | sudo bash
```

Update only the Hysteria binary:

```bash
curl -fsSL https://raw.githubusercontent.com/ethanzhrepo/hysteria2-1click/main/install.sh | sudo bash -s -- update
```

Prefer not to pipe into a shell? Either of these is equivalent:

```bash
# Process substitution (stdin stays attached to the terminal)
sudo bash <(curl -fsSL https://raw.githubusercontent.com/ethanzhrepo/hysteria2-1click/main/install.sh)

# Download first, inspect, then run
curl -fsSL https://raw.githubusercontent.com/ethanzhrepo/hysteria2-1click/main/install.sh -o install.sh
sudo bash install.sh
```

## Usage

If you cloned the repository:

Install:

```bash
sudo bash install.sh
```

or:

```bash
sudo bash install.sh install
```

Update only the Hysteria binary:

```bash
sudo bash install.sh update
```

Show help:

```bash
bash install.sh --help
```

## What It Installs

- Binary: `/usr/local/bin/hysteria`
- Server config: `/etc/hysteria/config.yaml`
- Client reference config: `/etc/hysteria/client.yaml`
- systemd service: `/etc/systemd/system/hysteria-server.service`

`update` preserves all configuration, certificate, key, and service files. It backs up the old binary before replacement and attempts rollback if version verification or service restart fails.

## Installation Prompts

The install flow asks for:

- UDP listen port, default `443`
- TLS mode:
  - ACME, recommended
  - self-signed certificate fallback
- ACME domain and email when ACME is selected
- host/domain/IP when self-signed mode is selected
- Hysteria auth password, hidden input; empty auto-generates a strong password
- optional Salamander obfs password, hidden input; empty auto-generates a strong password
- masquerade proxy URL, default `https://news.ycombinator.com/`; press Enter to accept the default, or enter `none` or `disable` to omit masquerade

When obfs is enabled, the script skips masquerade because obfs makes the server incompatible with standard HTTP/3 requests.
- local firewall changes when `ufw` or active `firewalld` is detected

## Network Requirements

Open the selected UDP port in your cloud provider security group.

For ACME mode, DNS for the selected domain must point to the server, and TCP `80` and `443` must be reachable from the public internet for certificate issuance.

The script can open local `ufw` or `firewalld` UDP rules, but it does not edit cloud provider security groups.

## Self-Signed Mode

Self-signed mode writes:

- `/etc/hysteria/server.crt`
- `/etc/hysteria/server.key`

The generated client config includes the certificate SHA256 pin through `tls.pinSHA256`. You can also copy `/etc/hysteria/server.crt` to clients and use the generated `tls.ca` path as a reference.

The script does not default to `tls.insecure: true`.

## Service Commands

Check status:

```bash
systemctl status hysteria-server --no-pager
```

View recent logs:

```bash
journalctl -u hysteria-server -n 80 --no-pager
```

Restart:

```bash
systemctl restart hysteria-server
```

## Local Development Checks

```bash
bash -n install.sh
bash tests/install_helpers_test.sh
bash install.sh --help
```

If `shellcheck` is installed:

```bash
shellcheck install.sh tests/install_helpers_test.sh
```

## Upstream References

- Hysteria 2 installation docs: https://v2.hysteria.network/docs/getting-started/Installation/
- Hysteria 2 full server config: https://v2.hysteria.network/docs/advanced/Full-Server-Config/
- Hysteria 2 full client config: https://v2.hysteria.network/docs/advanced/Full-Client-Config/
- Hysteria releases: https://github.com/apernet/hysteria/releases/latest
