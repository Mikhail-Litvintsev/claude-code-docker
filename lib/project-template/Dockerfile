# Опциональный проектный образ. FROM cc-image — расширение базового CC-образа.
# Создавайте только если проекту нужны CLI/runtime'ы, которых нет в cc-image:
# psql/mysql/mongo-клиенты, браузерные либы для Playwright, php/python/ruby/go,
# kubectl, aws, redis-cli и т.п.
#
# Если проекту достаточно базового cc-image — этот Dockerfile не нужен,
# а в ccd-config.sh оставьте IMAGE=cc-image.

FROM cc-image
USER root

# Пример: postgres-клиент + nc для wait-loop'ов в скриптах
# RUN apt-get update && apt-get install -y --no-install-recommends \
#         postgresql-client netcat-openbsd \
#     && rm -rf /var/lib/apt/lists/*

# Пример: Playwright + Chromium (тяжёлые зависимости)
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
