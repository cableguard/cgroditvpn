# Move host config into `~/infra-app`

Use this on hosts that still keep a machine profile gitignored inside `~/infra/`.
Goal: track `origin/main` for shared scripts and keep machine config/outputs in
the sibling `~/infra-app/` directory (**never commit** that dir).

## Layout after migration

```text
~/infra/                      # git — shared scripts only
  infra-env-helper.sh         # committed LOADER (not host values)
  infra-env-helper-shared.sh
  setup-host-oneoff.sh
  …

~/infra-app/                  # host-local — do NOT commit
  infra-env-helper.sh         # domains, ports, INFRA_APP_DOMAINS, …
  maintenance-status.md       # installed timers, firewall, hardening on this host
  trivy-scan-results/         # Trivy reports / SBOM
  README.md
```

Per-service secrets stay in each `~/<service>-app/` (`secrets/secrets.env`,
`env.local`, …). Do not move those into `infra-app`.

## Steps (run as the host user)

Identify the host profile name: `example` | `dedalo42` | `dedalo44` | `dedalo46` | `dedalo47` | `dedalo43`
(see `infra-env-helper.md`).

### 1. Preserve the live host profile before touching git

```bash
cd ~/infra
mkdir -p ~/infra-app/trivy-scan-results
chmod 750 ~/infra-app ~/infra-app/trivy-scan-results

# If the old gitignored profile is still in the repo, move it out FIRST.
# (Checkout will otherwise conflict or leave a stale file.)
if [[ -f infra-env-helper.sh ]] && ! grep -q 'INFRA_APP_DIR' infra-env-helper.sh 2>/dev/null; then
  mv -n infra-env-helper.sh ~/infra-app/infra-env-helper.sh
fi
```

### 2. Update the git checkout

Prefer a fast-forward pull. Only reset the checkout if you intend to discard
local commits **in `~/infra`** (the host profile must already be in `~/infra-app/`):

```bash
cd ~/infra
git fetch origin
git checkout main
git pull --ff-only
# If you must match origin/main exactly and discard local infra commits:
# git reset --hard origin/main
# git clean -fd
# Do NOT use git clean -x: that can remove ignored files you still need elsewhere.
```

Confirm the loader is present:

```bash
grep -q 'INFRA_APP_DIR' infra-env-helper.sh && echo "loader OK"
```

### 3. Populate / fix `~/infra-app`

**A. You moved a legacy profile in step 1** — normalize it for the new layout:

```bash
PROFILE=~/infra-app/infra-env-helper.sh

# Remove any INFRA_REPO / _INFRA_ENV_DIR defaults based on this file's dirname.
sed -i '/^_INFRA_ENV_DIR=/d' "$PROFILE"
sed -i '/^INFRA_REPO=/d' "$PROFILE"

# Ensure guard + shared source point at the git checkout.
grep -q 'INFRA_REPO:?' "$PROFILE" || \
  sed -i '1a\
: "${INFRA_REPO:?INFRA_REPO must be set by the infra checkout loader}"
' "$PROFILE"

sed -i 's|source "${_INFRA_ENV_DIR}/infra-env-helper-shared.sh"|source "${INFRA_REPO}/infra-env-helper-shared.sh"|' "$PROFILE"
grep -q 'source "${INFRA_REPO}/infra-env-helper-shared.sh"' "$PROFILE" || \
  printf '\n# shellcheck source=/dev/null\nsource "${INFRA_REPO}/infra-env-helper-shared.sh"\n' >>"$PROFILE"
```

**B. No legacy profile** — install from templates:

```bash
cd ~/infra
./bootstrap-infra-app.sh example   # or the named profile for this host
# Edit ~/infra-app/infra-env-helper.sh if this machine differs from the template.
```

`bootstrap-infra-app.sh` also creates `trivy-scan-results/`, seeds
`maintenance-status.md` from `docs/maintenance-status.example.md` (if missing), and
copy-migrates any legacy `~/infra/trivy-scan-results/*` (except the committed example).
After installing timers or hardening, update `~/infra-app/maintenance-status.md`.

### 4. Verify

```bash
bash -c 'source ~/infra/infra-env-helper.sh && \
  echo "user=$INFRA_USER app=$INFRA_APP_DIR out=$INFRA_TRIVY_RESULTS_DIR ports=${!INFRA_API_PORTS[*]}"'
```

Expected: `app` ends with `/infra-app`, `out` ends with `/infra-app/trivy-scan-results`,
`user` matches this host.

### 5. Optional: re-run host bootstrap

Only if you intend to re-apply firewall/certs/timers (idempotent-ish, but TLS/firewall
touch production):

```bash
cd ~/infra
sudo ./setup-host-oneoff.sh    # email defaults from INFRA_CERT_EMAIL
# Old names still work: setup-dedaloNN-host-oneoff.sh → same script
```

## Do / don’t

| Do | Don’t |
|----|--------|
| Keep `~/infra-app/` outside git | Commit `infra-app` or put secrets in `~/infra` |
| Fast-forward `~/infra` to `origin/main` | Commit live IPs, TLS keys, or `secrets.env` |
| Move legacy `infra-env-helper.sh` **before** updating git | Leave host values in the repo path (loader will break or wrong file wins) |
| Leave `~/idclawserver-app` etc. alone | Merge per-service `secrets.env` into `infra-app` |

## Overrides

- `INFRA_APP_DIR` — non-default sibling path
- `INFRA_OUTPUT_DIR` / `INFRA_TRIVY_RESULTS_DIR` — output location
- `INFRA_REPO` — unusual checkout path (loader sets this normally)

## Reference

- Templates / host inventories: [`../infra-env-helper.md`](../infra-env-helper.md)
- Host map: [`production-hosts.md`](./production-hosts.md)
- Bootstrap helper: `../bootstrap-infra-app.sh`
- Unified one-shot setup: `../setup-host-oneoff.sh`
