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
    qqbot)
        shift
        # The qqbot profile is not a shipped template: create it on first boot
        # by installing the official Tencent plugin (one-time; needs npm access).
        # Pin a version with QQBOT_PLUGIN, e.g. @tencent-connect/dsh-qqbot@0.5.5
        # The profile root marker is cordis.yml (created by `dsh plugin ... add`).
        PROFILE_DIR="${DSH_HOME}/profiles/qqbot"
        if [ ! -f "${PROFILE_DIR}/cordis.yml" ]; then
            echo "==> qqbot profile not found; installing ${QQBOT_PLUGIN:-@tencent-connect/dsh-qqbot@latest} (one-time)..."
            dsh plugin --profile qqbot add "${QQBOT_PLUGIN:-@tencent-connect/dsh-qqbot@latest}"
            echo "==> Plugin installed."
        fi
        # ReMe memory plugin (one-time). Idempotent marker = the profile's
        # package.json dependency (written by `dsh plugin add` via pnpm, then
        # auto-registered as a bundle layer). Endpoint comes from the REME_URL
        # env; the only file config is the zh guidance language, appended to
        # the profile patch. A failed install must not brick the QQBot.
        if [ "${REME_PLUGIN_INSTALL:-1}" = "1" ]; then
            if ! grep -q '"@agentscope-ai/reme-dsh-plugin"' "${PROFILE_DIR}/package.json" 2>/dev/null; then
                echo "==> installing ${REME_PLUGIN:-@agentscope-ai/reme-dsh-plugin@latest} into qqbot profile (one-time)..."
                if dsh plugin --profile qqbot add "${REME_PLUGIN:-@agentscope-ai/reme-dsh-plugin@latest}"; then
                    echo "==> ReMe plugin installed."
                else
                    echo "!! ReMe plugin install failed; QQBot continues WITHOUT memory. Fix the cause, then: docker compose restart dsh-qqbot"
                fi
            fi
            # Guidance language: zh (UI-less profile; config = profile patch entry)
            if grep -q '"@agentscope-ai/reme-dsh-plugin"' "${PROFILE_DIR}/package.json" 2>/dev/null \
               && ! grep -q 'id: reme-memory' "${PROFILE_DIR}/cordis.patch.yml" 2>/dev/null; then
                printf -- '- id: reme-memory\n  config:\n    language: zh\n' >> "${PROFILE_DIR}/cordis.patch.yml"
            fi
        fi
        exec dsh --profile qqbot "$@"
        ;;
    *)
        # Any other command is passed through as-is, e.g.:
        #   docker run <image> dsh headless "answer one task"
        #   docker run <image> dsh tui
        exec "$@"
        ;;
esac
