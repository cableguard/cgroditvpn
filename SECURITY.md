# Security policy

## Reporting a vulnerability

Please **do not** open a public GitHub issue for security problems.

Email **github@discernible.io** with:

- A description of the issue and its impact
- Steps to reproduce, or a proof of concept if you have one
- Affected scripts, hosts, or versions if known

We will acknowledge reports and work on a fix before any public disclosure.

## What belongs in this repository

This checkout is **shared scripts and example host templates only**.

Never commit:

- Host profiles from `~/infra-app/` (domains, ports, and live inventory for a machine)
- TLS private keys, `.pem` files, or Let's Encrypt live/archive trees
- `secrets.env`, `.env`, `env.local`, Vault tokens, or API keys
- SSH private keys or `authorized_keys` dumps
- Scan reports, logs, or other runtime output under `~/infra-app/trivy-scan-results/`

Copy [docs/maintenance-status.example.md](docs/maintenance-status.example.md) to `~/infra-app/maintenance-status.md` on each machine; do not check that file in.

## Using the scripts

These helpers configure SSH, firewalls, certificates, and containers. Run them only on machines you administer. Review each script before using `sudo`. Forks should replace the reference host templates with their own inventory and keep live IPs and credentials out of git.
