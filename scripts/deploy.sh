#!/usr/bin/env bash
# Build locally, sync to HAOS, and rebuild the addon.
#
# One-time HAOS setup (fresh install):
#   1. In HA: Settings → System → Operating System → SSH → paste your WSL public key
#      (generate one if needed: ssh-keygen -t ed25519 -C "wsl-dev")
#   2. Find your HAOS VM IP: Settings → System → Network (or check VMware/router)
#   3. Test: ssh root@<IP> -p 22222
#   4. Create the addon slot: ssh root@<IP> -p 22222 "mkdir -p /addons/donetick"
#   5. Set HAOS_HOST below or in a .env file next to this repo
#   6. Run: ./scripts/deploy.sh
#   7. In HA: Settings → Add-ons → Local Add-ons → install "Donetick Addon"
#
# Subsequent deploys: just run ./scripts/deploy.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADDON_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ADDON_DIR="$ADDON_ROOT/donetick"

# Load .env from the repo root if present
[[ -f "$ADDON_ROOT/.env" ]] && source "$ADDON_ROOT/.env"

HAOS_HOST="${HAOS_HOST:?'Set HAOS_HOST to your HAOS VM IP. E.g. export HAOS_HOST=192.168.1.x or add it to .env'}"
HAOS_SSH_PORT="${HAOS_SSH_PORT:-22222}"
HAOS_SSH_USER="${HAOS_SSH_USER:-root}"
ADDON_SLUG="${ADDON_SLUG:-donetick}"

SSH_OPTS=(-p "$HAOS_SSH_PORT" -o StrictHostKeyChecking=accept-new -o BatchMode=yes)
[[ -n "${HAOS_SSH_KEY:-}" ]] && SSH_OPTS+=(-i "$HAOS_SSH_KEY")

# ha CLI requires a login shell to pick up SUPERVISOR_TOKEN from the shell profile
ssh_ha() { ssh "${SSH_OPTS[@]}" "${HAOS_SSH_USER}@${HAOS_HOST}" bash -l -c "'$*'"; }

# ── Build ────────────────────────────────────────────────────────────────────
echo "==> Building..."
"$SCRIPT_DIR/build-dev.sh"

# ── Sync ─────────────────────────────────────────────────────────────────────
echo "==> Syncing addon folder to HAOS ${HAOS_SSH_USER}@${HAOS_HOST}:${HAOS_SSH_PORT}..."

# Sync everything except the two Dockerfiles (we'll place the dev one as Dockerfile)
rsync -az --delete \
    --exclude=".git" \
    --exclude="Dockerfile" \
    --exclude="Dockerfile.dev" \
    -e "ssh ${SSH_OPTS[*]}" \
    "$ADDON_DIR/" \
    "${HAOS_SSH_USER}@${HAOS_HOST}:/addons/${ADDON_SLUG}/"

# Dockerfile.dev becomes the active Dockerfile on HAOS
rsync -az \
    -e "ssh ${SSH_OPTS[*]}" \
    "$ADDON_DIR/Dockerfile.dev" \
    "${HAOS_SSH_USER}@${HAOS_HOST}:/addons/${ADDON_SLUG}/Dockerfile"

# Strip the image: field so the supervisor builds from Dockerfile instead of pulling from ghcr.io
ssh "${SSH_OPTS[@]}" "${HAOS_SSH_USER}@${HAOS_HOST}" \
    "sed -i '/^image:/d' /addons/${ADDON_SLUG}/config.yaml"

# ── Reload store ─────────────────────────────────────────────────────────────
# Reload only the supervisor (rescans /addons) without pulling remote repo updates
echo "==> Refreshing store to pick up local addon..."
ssh_ha "ha store refresh"

# ── Install or rebuild ───────────────────────────────────────────────────────
# Detect whether the addon is already installed (state field present and not "none")
ADDON_STATE=$(ssh "${SSH_OPTS[@]}" "${HAOS_SSH_USER}@${HAOS_HOST}" \
    "bash -l -c 'ha apps info local_${ADDON_SLUG} --raw-json 2>/dev/null | python3 -c \"import sys,json; d=json.load(sys.stdin); print(d.get(\\\"data\\\",{}).get(\\\"state\\\",\\\"none\\\"))\" 2>/dev/null || echo none'")

if [[ "$ADDON_STATE" == "none" || "$ADDON_STATE" == "unknown" ]]; then
    echo ""
    echo "========================================================"
    echo " First-time setup: open HA and install the addon from UI"
    echo "   http://${HAOS_HOST}:8123/hassio/store"
    echo "   → Local add-ons → Donetick Addon → Install"
    echo " Then re-run ./scripts/deploy.sh to build and start it."
    echo "========================================================"
    exit 0
fi

echo "==> Rebuilding image on HAOS (docker build runs on the VM)..."
ssh_ha "ha apps rebuild local_${ADDON_SLUG}"

echo "==> Starting addon..."
ssh_ha "ha apps start local_${ADDON_SLUG}"

echo "==> Tailing logs (Ctrl-C to stop)..."
ssh "${SSH_OPTS[@]}" "${HAOS_SSH_USER}@${HAOS_HOST}" \
    "sudo docker logs --follow --tail=80 app_local_${ADDON_SLUG}"
