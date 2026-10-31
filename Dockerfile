# ====== DeepSeek Harness (dsh) Docker Image ======
# Base: Debian 13 (trixie) standard image with official Node.js 24
# Rootless npm global install with local prefix.
# Self-extracting upgrade model (same as OpenClaw image):
#   - the image bundles a factory backup of the npm prefix (/opt/dsh-backup.tar.xz)
#   - on first start with an empty volume, entrypoint.sh restores it
#   - in-place upgrade without rebuilding the image:
#       docker exec <container> npm install -g @deepseek-ai/dsh@latest
#       docker restart <container>

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

# Build-time install of dsh (runs as root, installs to node-owned prefix).
# pnpm is required by `dsh plugin` (profile plugin management forwards to pnpm),
# e.g. installing the official QQ Bot plugin:
#   dsh plugin --profile qqbot add @tencent-connect/dsh-qqbot
ARG DSH_VERSION=latest
RUN npm install -g @deepseek-ai/dsh@${DSH_VERSION} pnpm && \
    npm cache clean --force

# Factory backup of the initial install for volume first-time initialization.
# When a bind mount is empty on first start, entrypoint restores from this archive.
RUN tar -I 'xz -6' -cf /opt/dsh-backup.tar.xz -C /home/node .npm-global

# Ensure node user owns the npm global directory and cache
RUN chown -R node:node /home/node/.npm-global && \
    install -d -m 0755 -o node -g node /home/node/.npm

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
