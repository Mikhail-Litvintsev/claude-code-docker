# Optional project image. FROM cc-image — extends the base CC image.
# Only create this if the project needs CLIs/runtimes not present in cc-image:
# psql/mysql/mongo clients, browser libs for Playwright, php/python/ruby/go,
# kubectl, aws, redis-cli, etc.
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
# Reference: <setup>/wiam/{Dockerfile,mcp.json} + <projects-root>/wiam/.claude/playwright-mcp-config.json
# Notes for cap-drop=ALL containers (the ccd default):
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

USER claude

# RUN playwright install chromium
