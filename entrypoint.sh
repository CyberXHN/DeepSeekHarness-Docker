#!/bin/bash
set -e

NPM_GLOBAL_DIR=/home/node/.npm-global
BACKUP_FILE=/opt/dsh-backup.tar.xz
DSH_PKG_DIR="${NPM_GLOBAL_DIR}/lib/node_modules/@deepseek-ai/dsh"

# Initialize npm global directory: extract from factory backup.
# Runs as node user, no chown needed (Dockerfile pre-sets directory permissions).
# When a bind mount volume is empty on first start, restore from the
# image-bundled archive so in-place upgrades persist in the volume.
if [ ! -f "${DSH_PKG_DIR}/package.json" ]; then
    echo "==> dsh not found in volume, initializing from image backup..."
    tar -xJf "${BACKUP_FILE}" -C /home/node
    echo "==> Initialized."
fi

echo "==> dsh version: $(dsh --version 2>/dev/null || echo 'unknown')"

case "${1-web}" in
    web)
        shift
        # dsh rejects wildcard bind addresses; bind the container's own IP so
        # published ports (-p / ports:) can reach the listener.
        HOST_IP="$(hostname -i 2>/dev/null | awk '{print $1}')"
        if [ -z "${HOST_IP}" ]; then
            HOST_IP="127.0.0.1"
        fi
        echo "==> Starting dsh web on ${HOST_IP}:3080"
        echo "==> The printed URL below carries the launch token; replace its host with the address you use to reach this container (e.g. http://localhost:3080)."
        # shellcheck disable=SC2086
        exec dsh web --host "${HOST_IP}" --no-open ${DSH_WEB_EXTRA_ARGS:-} "$@"
        ;;
    *)
        # Any other command is passed through as-is, e.g.:
        #   docker run <image> dsh headless "answer one task"
        #   docker run <image> dsh tui
        exec "$@"
        ;;
esac
