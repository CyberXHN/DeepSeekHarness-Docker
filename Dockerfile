# ====== DeepSeek Harness (dsh) Docker Image ======
# Base: Debian 13 (trixie) standard image with official Node.js 24.
# Backup-only layout (multi-stage): the runtime image bundles ONLY the
# compressed factory backup (/opt/dsh-backup.tar.xz) — the unpacked npm
# prefix never enters the image layers (saves ~2.2GB: unpacked copy +
# chown copy-up copy). Self-extracting upgrade model:
#   - on first start with an empty volume, entrypoint.sh restores the backup
#   - in-place upgrade without rebuilding the image:
#       docker exec <container> npm install -g @deepseek-ai/dsh@latest
#       docker restart <container>

# ------ Stage 1: install dsh as node user, pack the factory backup ------
FROM node:24-trixie AS dsh-packager

# Rootless npm global install with local prefix. Installing as node from
# the start makes every file node-owned, so no chown pass (and no chown
# copy-up layer) is ever needed.
ENV NPM_CONFIG_PREFIX=/home/node/.npm-global
ENV PATH="/home/node/.npm-global/bin:${PATH}"

# pnpm is required by `dsh plugin` (profile plugin management forwards to pnpm),
# e.g. installing the official QQ Bot plugin:
#   dsh plugin --profile qqbot add @tencent-connect/dsh-qqbot
ARG DSH_VERSION=latest
USER node
RUN npm install -g @deepseek-ai/dsh@${DSH_VERSION} pnpm && \
    npm cache clean --force && \
    tar -I 'xz -6' -cf /tmp/dsh-backup.tar.xz -C /home/node .npm-global

# ------ Stage 2: runtime image (backup only, no unpacked dsh) ------
FROM node:24-trixie

USER root

# Runtime dependencies for the harness and its agent tools
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates procps hostname curl git git-lfs lsof openssl python3 \
        dumb-init tzdata xz-utils less nano vim-tiny wget \
        iputils-ping dnsutils net-tools iproute2 openssh-client && \
    git lfs install && \
    ln -sf /usr/bin/python3 /usr/bin/python && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# ====== dsh: rootless npm local-prefix install ======
# Redirect npm global prefix to node user's home directory.
# This allows npm install -g (and in-place upgrades) without root privileges:
# npm install -g writes to /home/node/.npm-global instead of /usr/local.
ENV NPM_CONFIG_PREFIX=/home/node/.npm-global
ENV PATH="/home/node/.npm-global/bin:${PATH}"

# Factory backup of the initial install for volume first-time initialization.
# When a bind mount is empty on first start, entrypoint restores from this archive.
COPY --from=dsh-packager --chown=0:0 /tmp/dsh-backup.tar.xz /opt/dsh-backup.tar.xz

# Pre-create state directories with correct ownership for volume mounting.
# Named volumes / bind mounts inherit these permissions on first creation.
RUN install -d -m 0700 -o node -g node /home/node/.dsh && \
    install -d -m 0700 -o node -g node /home/node/.agents && \
    install -d -m 0755 -o node -g node /home/node/workspace

# Copy entrypoint initialization script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV NODE_ENV=production
ENV DSH_HOME=/home/node/.dsh
ENV DSH_AGENTS_HOME=/home/node/.agents

WORKDIR /home/node/workspace

USER node

EXPOSE 3080

ENTRYPOINT ["dumb-init", "--", "/entrypoint.sh"]

# dsh web only serves loopback by default and rejects wildcard bind addresses,
# so the entrypoint binds the container's own IP (hostname -i) — the
# upstream-sanctioned way to make published ports reach the listener.
# The health probe does the same interface lookup.
HEALTHCHECK --interval=3m --timeout=10s --start-period=90s --retries=3 \
  CMD ["node", "-e", "const n=require('net'),o=require('os');const e=Object.values(o.networkInterfaces()).flat().find(i=>i&&!i.internal&&i.family=='IPv4');const ip=(e&&e.address)||'127.0.0.1';const s=n.connect(3080,ip,()=>{s.destroy();process.exit(0)});s.on('error',()=>process.exit(1))"]

# "web" is a marker word handled by entrypoint.sh; override with any other
# command, e.g.: docker run <image> dsh headless "answer one task"
CMD ["web"]
