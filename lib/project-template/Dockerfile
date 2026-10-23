# Optional project image. FROM cc-image — extends the base CC image.
# Only create this if the project needs CLIs/runtimes not present in cc-image:
# psql/mysql/mongo clients, browser libs for Playwright, php/python/ruby/go,
# kubectl, aws, redis-cli, etc.
#
# Already in cc-image, do NOT duplicate: git, curl, jq, ripgrep, fd-find,
# docker-cli + compose plugin, LANG=C.UTF-8, and the document conversion
# toolchain used by ~/.claude/scripts/pipeline-sources.sh: poppler-utils
# (pdftotext), libreoffice-*-nogui (soffice), python3 + python3-openpyxl.
#
# If the base cc-image is enough, this Dockerfile is not needed,
# and ccd-config.sh should keep IMAGE=cc-image.

FROM cc-image
USER root

# Example: postgres-client + nc for wait-loops in scripts
# RUN apt-get update && apt-get install -y --no-install-recommends \
#         postgresql-client netcat-openbsd \
#     && rm -rf /var/lib/apt/lists/*

# Example: Playwright + Chromium (heavy dependencies)
# Reference: README § MCP servers (mcp.json + playwright-mcp-config.json snippets)
# Notes for cap-drop=ALL containers (the ccd default):
#   - In mcp.json set "command": "/usr/local/bin/playwright-mcp" (the baked bin),
#     NOT "npx @playwright/mcp@latest": npx re-resolves to a newer release whose
#     Chromium revision is not installed in the image, so browser calls fail with
#     "browser is not installed". Rebuild the image to update; the bin always matches.
#   - In mcp.json args, do NOT pass --browser=chromium — "chromium" is not a valid
#     MCP CLI value (allowed: chrome/firefox/webkit/msedge). Chromium is the default.
#   - --browser-arg does NOT exist. Pass chromium flags via launchOptions.args
#     in a --config <path> JSON file.
#   - chromium will fail with "No usable sandbox" — set "chromiumSandbox": false
#     in launchOptions of the same --config file (NOT the chromium --no-sandbox flag).
# RUN apt-get update && apt-get install -y --no-install-recommends \
#         libnss3 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 libdbus-1-3 \
#         libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 \
#         libgbm1 libpango-1.0-0 libcairo2 libasound2 \
#         fonts-noto-color-emoji \
#     && rm -rf /var/lib/apt/lists/*
# RUN npm install -g @playwright/mcp \
#     && PW_VERSION="$(node -p "require('/usr/local/lib/node_modules/@playwright/mcp/node_modules/playwright/package.json').version")" \
#     && npm install -g "playwright@${PW_VERSION}"

# Example: Chrome DevTools MCP (device emulation, throttling, performance traces, Lighthouse)
# Reference: README § MCP servers (mcp.json snippet)
# Notes for cap-drop=ALL containers (the ccd default):
#   - The server launches the system Google Chrome by channel; the Playwright Chromium
#     above is NOT picked up, so install google-chrome-stable (amd64 only).
#   - In mcp.json pass --chrome-arg=--no-sandbox --chrome-arg=--disable-setuid-sandbox
#     --chrome-arg=--disable-dev-shm-usage, and set CHROME_DEVTOOLS_MCP_NO_CONFIG_DISCOVERY=1 in env.
#   - --filesystem-root must point at an existing directory (create it in the project init.sh).
# RUN curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
#         | gpg --dearmor -o /etc/apt/keyrings/google-chrome.gpg \
#     && chmod a+r /etc/apt/keyrings/google-chrome.gpg \
#     && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
#         > /etc/apt/sources.list.d/google-chrome.list \
#     && apt-get update \
#     && apt-get install -y --no-install-recommends google-chrome-stable \
#     && rm -rf /var/lib/apt/lists/*
# RUN npm install -g chrome-devtools-mcp

# Example: host key of a corporate git host (git over ssh to anything other than
# github.com / gitlab.com / bitbucket.org, which cc-image already knows).
# Create <setup>/<project>/ssh-known-hosts on the host first:
#   ssh-keyscan -p <port> <host> > <setup>/<project>/ssh-known-hosts
# The file holds the keys of a specific host, so it is not part of the template.
# COPY --chown=claude:claude ssh-known-hosts /tmp/ssh-known-hosts
# RUN cat /tmp/ssh-known-hosts >> /home/claude/.ssh/known_hosts && rm /tmp/ssh-known-hosts

USER claude

# RUN playwright install chromium
