# Contributing

Thanks for helping improve this host-automation toolkit.

## Before you start

- Keep machine-specific config in `~/infra-app/` (or `INFRA_APP_DIR`). Do not add live IPs, secrets, or private keys to pull requests.
- Prefer small, focused changes: one concern per pull request.
- Match the existing bash style and the script naming rules in the [README](README.md#script-naming).

## Development setup

1. Clone the repository and work on AlmaLinux 10 (or a close RHEL 10 compatible host) when changing installers or systemd units.
2. Install `jq` and `podman` at minimum. Certificate and firewall scripts also need `certbot`, `httpd`, and `iptables` as described in the README.
3. Bootstrap a disposable profile rather than pointing scripts at production:

   ```bash
   ./bootstrap-infra-app.sh example
   # or: INFRA_APP_DIR=/tmp/infra-app-dev ./bootstrap-infra-app.sh example
   ```

4. Most scripts accept `help` (or `-h` / `--help`).

## Pull requests

- Describe **why** the change is needed and how you tested it.
- If you add a script, document it in [docs/readme.md](docs/readme.md) and, when it has a run cadence, in [docs/maintenance-status-roadmap.md](docs/maintenance-status-roadmap.md).
- Host profile templates live in [infra-env-helper.md](infra-env-helper.md). Keep bash fences extractable by `bootstrap-infra-app.sh` (`INFRA_USER=` plus `source "${INFRA_REPO}/infra-env-helper-shared.sh"`).
- Do not weaken SSH, firewall, or certificate checks without a clear reason.

## Code of conduct

Participation is covered by the [Code of Conduct](CODE_OF_CONDUCT.md).
