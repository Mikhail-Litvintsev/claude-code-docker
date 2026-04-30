FROM node:22-slim

ARG UID=1000
ARG GID=1000

RUN apt-get update && apt-get install -y --no-install-recommends \
        git curl ca-certificates gnupg openssh-client \
        ripgrep fd-find jq \
    && rm -rf /var/lib/apt/lists/*

RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && chmod a+r /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release; echo $VERSION_CODENAME) stable" \
        > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

RUN userdel -r node 2>/dev/null || true; \
    groupdel node 2>/dev/null || true; \
    groupadd -g ${GID} claude && \
    useradd -u ${UID} -g ${GID} -m -s /bin/bash claude

RUN mkdir -p /home/claude/.ssh \
    && ssh-keyscan github.com gitlab.com bitbucket.org >> /home/claude/.ssh/known_hosts \
    && chown -R claude:claude /home/claude/.ssh \
    && chmod 700 /home/claude/.ssh \
    && chmod 644 /home/claude/.ssh/known_hosts

RUN mkdir -p /home/claude/.claude && chown -R claude:claude /home/claude/.claude
RUN mkdir -p /home/claude/.config/ccd && chown -R claude:claude /home/claude/.config

ENV CLAUDE_CONFIG_DIR=/home/claude/.claude

ENTRYPOINT []
USER claude
WORKDIR /home/claude
