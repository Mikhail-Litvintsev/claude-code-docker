# ТЗ: подключение нового проекта к Claude Code Docker

Этот документ — техническое задание агенту Claude Code. Пройди по шагам, проанализируй проект, согласуй архитектурные решения с пользователем, создай артефакты, верифицируй.

## Контекст инфраструктуры

Сетап разделён на две части:

**Общая инфраструктура** (живёт в setup-репозитории):
- `<setup>/Dockerfile` — образ `cc-image` (база CC-контейнеров).
- `<setup>/bin/ccd` — обёртка: walk-up по дереву от `$PWD` до предка, у которого есть `<setup>/<basename(ancestor)>/ccd-config.sh`; запуск CC-контейнера для соответствующего проекта. Конфиг живёт в setup-репо, а не в bind-mount проекта (security: иначе CC мог бы менять флаги изнутри сессии).
- `<setup>/cc-docker-proxy/haproxy.cfg` — конфиг прокси docker API (`tecnativa/docker-socket-proxy` + custom deny-rule на `/containers/create`); поднимается корневым `init.sh` как контейнер `cc-docker-proxy` в `cc-net`. CC-сессии говорят с docker daemon только через него (`DOCKER_HOST=tcp://cc-docker-proxy:2375`).
- `<setup>/lib/init-helpers.sh` — bash-функции (логирование, идемпотентные docker-проверки).
- `<setup>/init.sh` — корневой инициализатор: prerequisites, общая сеть `cc-net`, volume `claude-auth`, контейнер `cc-docker-proxy`, сборка `cc-image`, PATH в `~/.bashrc`, цикл по `<setup>/*/init.sh`.

**Проектные настройки** (НЕ в setup-репозитории — локальные на каждой машине):
- `<setup>/<project-name>/` — папка с настройками конкретного подключённого проекта. Парная к `<projects-root>/<project-name>/` (одно и то же имя).

Корневой `init.sh` итерируется по `<setup>/*/init.sh`. Папка идентифицируется по наличию `init.sh` внутри. Папки без `init.sh` (`bin/`, `lib/`, `cc-docker-proxy/`) пропускаются молча.

## Соглашения

- Имя `<setup>/<project-name>/` ОБЯЗАНО совпадать с именем `<projects-root>/<project-name>/`. По имени папки в setup'е находится связанный проект.
- Образ проекта (если требуется расширение `cc-image`): `cc-image-<project-name>`.
- Сервисные контейнеры проекта: `cc-<project-name>-<service>` (например `cc-expro-vpn`).
- Образы сервисных контейнеров: `cc-<project-name>-<service>-image`.

## Входные данные

Запросить у пользователя:
1. `<project-name>` — имя проектной папки (должно совпадать с папкой в `<projects-root>`).
2. Подтверждение, что `<projects-root>/<project-name>/` существует и готов (репозиторий клонирован, зависимости установлены).

## Шаг 1. Анализ проекта

Прочитать `<projects-root>/<project-name>/` и выяснить, что нужно проектному init.sh.

### 1.1. Compose-сети
```bash
find <projects-root>/<project-name> -maxdepth 4 -name 'docker-compose*.y*ml' \
    -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/vendor/*'
```
Прочитать каждый файл, извлечь имена сетей (секция `networks:`). Compose обычно даёт сетям имя `<stack-folder>_<network>` (если `name:` не задано явно). Зафиксировать список — это будущий `COMPOSE_NETWORKS` массив в `ccd-config.sh`.

### 1.2. Host-bound скрипты
```bash
find <projects-root>/<project-name> -maxdepth 3 -name '*.sh' \
    -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/vendor/*'
```
Прочитать каждый. Признаки host-bound:
- `127.0.0.1` или `localhost` для DB/сервисов;
- `./vpn-on.sh`, `./vpn-off.sh`, прочие host-only утилиты;
- абсолютные пути на `/home/<user>/...` или `/etc/...`;
- предполагается запуск с хоста, не из контейнера.

Каждый такой скрипт — кандидат на адаптацию (Шаг 6).

### 1.3. VPN/туннель к удалённой инфре
Если в скриптах или конфигах есть упоминание внешнего хоста через `127.0.0.1:<port>` (типичный признак SSH-туннеля или socat-релея на хосте), а реальный хост недоступен напрямую из контейнерной сети — **нужен сервисный VPN-контейнер** в общей сети `cc-net`. Имя контейнера: `cc-<project-name>-vpn`. Типичная реализация — xray + socat внутри сервисного контейнера. Готовые шаблоны: `<setup>/lib/project-template/Dockerfile.vpn` и `<setup>/lib/project-template/vpn-entrypoint.sh` — копируются в `<setup>/<project-name>/` без изменений; кастомизация под проект — только через `vpn-config/config.json` (xray-конфиг с реальным upstream) и переменные `DB_REMOTE_HOST`/`DB_REMOTE_PORT` в `docker create` из проектного `init.sh`. Скелет init.sh, собирающий такой контейнер, — `<setup>/lib/project-template/init.sh`.

### 1.4. Системные требования
Что использует проект, чего нет в базовом `cc-image`:
- Playwright/Cypress — браузерные либы + Chromium;
- `psql`, `mysql`, `mongo` клиенты;
- `nc`, `redis-cli`, `kubectl`, `aws` CLI;
- runtime'ы (php, python, ruby, go) — если нужно гонять CLI проекта внутри CC-контейнера.

Если что-то нужно сверх `cc-image` — отдельный `<setup>/<project-name>/Dockerfile` (FROM cc-image). Шаблон с закомментированными примерами расширений (postgres-client, Playwright и т.п.) — `<setup>/lib/project-template/Dockerfile`.

### 1.5. Источники секретов на хосте
- `.env`-файлы в проекте;
- backup'ы в `temp-backup/` (если делалась миграция);
- ENV-переменные пользователя.

Каждый источник — спросить у пользователя для подтверждения.

## Шаг 2. Решения по архитектуре (согласовать с пользователем)

На основе Шага 1 — задать пользователю отдельные вопросы:

| Решение | Когда нужно |
|---|---|
| `<setup>/<project-name>/Dockerfile` (cc-image-<project-name>) | Шаг 1.4 нашёл нестандартные требования |
| Сервисный контейнер (Dockerfile.<svc> + entrypoint + конфиг) | Шаг 1.3 нашёл VPN/туннель ИЛИ проекту нужен dedicated сервис |
| Непустой `COMPOSE_NETWORKS` | Шаг 1.1 нашёл compose-сети, к которым CC должен подключаться |
| Адаптация скриптов в `.claude/scripts/` | Шаг 1.2 нашёл host-bound скрипты, которые должны работать из CC-контейнера |
| Файл `<projects-root>/<project-name>/.claude/<name>-credentials.env` | У проекта есть пароли/ключи, которые нужны скриптам |

Если ничего сверх базового не нужно — `<setup>/<project-name>/` содержит только минимальный `init.sh`, который генерирует `ccd-config.sh` (с пустым `COMPOSE_NETWORKS=()` и пустым `VPN_CONTAINER`).

**Не действовать слепо**: на каждом решении явно показать пользователю, что нашёл в Шаге 1, что предлагаешь делать, и дождаться подтверждения.

## Шаг 3. Создать структуру папок

В `<setup>/<project-name>/`:
```
init.sh                         # обязательный
ccd-config.sh                   # генерирует init.sh; конфиг обвязки лежит в setup-репо, а не в bind-mount проекта — иначе CC из сессии мог бы менять свои же EXPOSE_GIT_*-флаги
mcp.json                        # генерирует init.sh пустым; project-level MCP-серверы. Источник правды — здесь, не <projects-root>/.../.mcp.json (read-only bind-mount + --strict-mcp-config в ccd → анти-tampering)
[Dockerfile]                    # опциональный
[Dockerfile.<svc>]              # опциональный
[<svc>-entrypoint.sh]           # опциональный
[<svc>-config/]                 # опциональный (секреты внутри)
```

В `<projects-root>/<project-name>/.claude/`:
```
[<name>-credentials.env]        # генерирует init.sh, chmod 600
[scripts/]                      # адаптированные скрипты, если есть
```

`<setup>/<project-name>/` целиком исключена из setup-репозитория whitelist'ом — секреты внутри в безопасности.

`<projects-root>/<project-name>/` — отдельный репозиторий проекта (если это git-репо). В этом случае его `.gitignore` обязан игнорировать `db-credentials.env` (или другое имя `*-credentials.env`) и любые `*.env`. Проектный init.sh при генерации credentials-файла **обязан вывести предупреждение** об этом. Если проект — не git-репо, правило неприменимо, секреты в `.claude/` локальные по дизайну.

## Шаг 4. Реализовать `<setup>/<project-name>/init.sh`

Полный рабочий пример с VPN-контейнером — `<setup>/lib/project-template/init.sh`. Имя проекта в шаблоне — `expro` (example project); при адаптации заменить `expro` на `<project-name>`, переменные `EXPRO_*` → `<PROJECT_NAME>_*`, скорректировать `COMPOSE_NETWORKS` и `DB_REMOTE_HOST`, удалить блоки VPN/credentials, если они проекту не нужны. Соседние файлы шаблона (`Dockerfile`, `Dockerfile.vpn`, `vpn-entrypoint.sh`, `mcp.json`) копируются в `<setup>/<project-name>/` по необходимости — см. Шаг 3.

Минимальный скелет (без VPN, без проектного Dockerfile, без credentials):

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(dirname "$(realpath "$0")")
SETUP_DIR=$(dirname "$SCRIPT_DIR")
PROJECTS_ROOT=$(dirname "$SETUP_DIR")
PROJECT_NAME=$(basename "$SCRIPT_DIR")
PROJECT_DIR="$PROJECTS_ROOT/$PROJECT_NAME"

source "$SETUP_DIR/lib/init-helpers.sh"

REBUILD=0
REBUILD_BASE_DERIVED=0
while [ $# -gt 0 ]; do
    case "$1" in
        --rebuild)              REBUILD=1; shift ;;
        --rebuild-base-derived) REBUILD_BASE_DERIVED=1; shift ;;
        *) cc_die "$PROJECT_NAME/init.sh: unknown flag $1" ;;
    esac
done

# 1. Валидация: PROJECT_DIR должен существовать
[ -d "$PROJECT_DIR" ] || cc_die "проект $PROJECT_DIR не найден"
cc_log_skip "проект найден: $PROJECT_DIR"

# 2. Копирование секретов в <setup>/<project-name>/<svc>-config/ (если требуется)
# 3. Сборка cc-image-<project-name> (если есть Dockerfile, FROM cc-image)
# 4. Сборка cc-<project-name>-<svc>-image (если есть Dockerfile.<svc>, может быть FROM любая база)
# 5. Генерация <name>-credentials.env (chmod 600) — если файла нет, иначе SKIP
# 6. Генерация ccd-config.sh — если файла нет, иначе SKIP с проверкой на отсутствующие поля
# 7. Генерация mcp.json (пустой `{"mcpServers": {}}`) — если файла нет, иначе SKIP
# 8. Создание сервисных контейнеров (`docker create` без run, идемпотентно через rm -f + create)

cc_log_ok "$PROJECT_NAME/init.sh: ok"
```

### Идемпотентность
Каждый ресурс — `inspect → SKIP / create`. Никаких безусловных действий, ломающих существующее состояние.

### Не перезаписывать существующие конфиги
`ccd-config.sh` и `<name>-credentials.env` пишутся ТОЛЬКО при отсутствии. Если файл есть — сравнить набор обязательных ключей с шаблоном внутри init.sh; при несовпадении — `cc_log_info` с диагностикой, пользователь обновляет вручную.

### Каскад флагов
- `--rebuild` → пересобрать ВСЕ образы проекта (включая сервисные с другой базой). Сервисные контейнеры пересоздать.
- `--rebuild-base-derived` (передаёт корневой init.sh при расхождении UID/GID `cc-image`) → пересобрать ТОЛЬКО образы с `FROM cc-image`. Сервисные с другой базой (`debian:bookworm-slim` и т.п.) НЕ трогать. Сервисные контейнеры тоже не пересоздавать (их образ не менялся).

### Источники секретов — явные ветки, не магия
Для каждого секрета: явный список приоритетов источников (ENV-переменные → .env-файл проекта → backup → fail с инструкцией). Каждый источник — отдельная ветка в коде.

## Шаг 5. Сгенерировать `ccd-config.sh`

Шаблон (init.sh пишет это в `<setup>/<project-name>/ccd-config.sh`, chmod 644 — путь в setup-репо, не в проектной папке: bind-mount проекта в cc-сессии read-write, и если бы конфиг был там, CC мог бы переписать `EXPOSE_GIT_*` своими руками):

```bash
IMAGE=cc-image-<project-name>          # или cc-image, если без своего Dockerfile
CONTAINER_NAME_PREFIX=cc-<project-name>
COMPOSE_NETWORKS=("net1" "net2")        # из Шага 1.1; пустой массив (), если не нужны
VPN_CONTAINER=cc-<project-name>-vpn     # пустая строка "", если VPN не нужен
VPN_REFCOUNT_FILE="$PROJECT_DIR/.claude/cc-<project-name>-vpn.users"
EXPOSE_GIT_IDENTITY=1   # CC коммитит от имени пользователя (sanitized bind-mount ~/.gitconfig в /home/claude/.gitconfig:ro)
EXPOSE_GIT_PUSH=0       # =1 — CC пушит через $SSH_AUTH_SOCK (доступ ко всем репо в ssh-agent!)
EXPOSE_GITCONFIG=0      # =1 — bind-mount ~/.gitconfig целиком, без sanitization (signingkey, credential.helper, url-rewrites)
```

`$PROJECT_DIR` устанавливается обёрткой `bin/ccd` ДО `source` конфига — внутри шаблона это литерал `$PROJECT_DIR`, не expand при создании.

`COMPOSE_NETWORKS` обязан быть **bash-массивом**, не строкой — обёртка `ccd` итерируется через `"${COMPOSE_NETWORKS[@]}"`. Пустой массив `()` = не подключаться ни к каким compose-сетям.

`VPN_CONTAINER=""` (пустая строка) = VPN-логика отключена; обёртка не делает refcount-операций.

Полная reference-таблица всех переменных `ccd-config.sh` (включая базовые: `IMAGE`, `COMPOSE_NETWORKS`, `VPN_CONTAINER` и т.д.) — в `<setup>/README.md`, раздел «Конфигурация проектного `ccd-config.sh`». Default'ы из шаблона: `IDENTITY=1, PUSH=0, GITCONFIG=0` — CC коммитит локально, ревью и push делает пользователь.

## Шаг 6. Адаптировать host-bound скрипты проекта (если нашёл в Шаге 1.2)

Для каждого скрипта:
1. Backup в `<projects-root>/<project-name>/temp-backup/<original-path>` (с сохранением структуры).
2. Перенести в `<projects-root>/<project-name>/.claude/scripts/<name>.sh`.
3. Заменить:
   - `127.0.0.1`/`localhost` для прокси к удалённому хосту → DNS сервисного контейнера (`cc-<project-name>-vpn` и т.п.) — резолвится по сети `cc-net`.
   - Хостовые абсолютные пути → пути внутри контейнера или относительные.
   - Загрузка секретов: вместо хардкода — `source "$(dirname "$(realpath "$0")")/../<name>-credentials.env"`.
   - Защита от мутаций (для DB-скриптов): grep на forbidden операции (INSERT/UPDATE/DROP/...).
4. **НЕ управлять жизненным циклом сервисных контейнеров** — это делает `bin/ccd` через trap+refcount. Скрипт делает только `docker start <vpn>` (идемпотентно, на случай первого вызова) + `nc -z` ожидание готовности.
5. `chmod 755`.
6. Обновить документацию проекта (CLAUDE.md, README.md и т.п.) — заменить старые пути и инструкции на `.claude/scripts/<name>.sh`.

Backup оригиналов в `temp-backup/` обязателен ДО изменения.

## Шаг 7. Запуск init.sh

```bash
bash <setup>/<project-name>/init.sh
```
или через корневой:
```bash
bash <setup>/init.sh --project <project-name>
```

Ожидаемое: образы созданы, сервисные контейнеры в `Created`, `ccd-config.sh` и `<name>-credentials.env` сгенерированы.

## Шаг 8. Верификация

```bash
cd <projects-root>/<project-name> && ccd
```

Внутри сессии CC:
- `pwd` → `<projects-root>/<project-name>`.
- `id` → `claude:claude` с UID/GID хоста.
- Compose-сервисы доступны: `nc -zv <service-hostname> <port>` для каждой сети из `COMPOSE_NETWORKS`.
- Адаптированные скрипты работают (конкретная проверка зависит от проекта; например, тестовый SELECT через адаптированный db-query.sh).
- `/exit` — контейнер `cc-<project-name>-<pid>` удалён по `--rm`. Сервисные контейнеры остановлены, если refcount пуст.

После верификации — подключение завершено. На новой машине этот же проект разворачивается копированием `<setup>/<project-name>/` + запуском корневого `init.sh`.

## Тонкости

- При коллизии имён сервисов между проектами — соглашение `cc-<project-name>-<service>` гарантирует изоляцию. НЕ переиспользовать чужие сервисные контейнеры.
- Если проектный init.sh упал — корневой `init.sh` не блокируется, итерируется дальше. Финальная сводка покажет `[FAIL] проект <name>`. exit code корневого станет non-zero.
- Все секреты (xray-config, db-credentials и любые проектные) генерируются ТОЛЬКО при отсутствии файла. Перезапись — никогда (см. «Не перезаписывать» в Шаге 4). Шаблон-источник истины — внутри проектного init.sh; при изменении полей старые файлы обновляются вручную после диагностики.
- `<setup>/<project-name>/` целиком исключена из setup-репозитория. На новую машину переносится копированием либо подключается с нуля по этому ТЗ.
- OAuth Claude Code — отдельный однократный шаг **после** первого `ccd`-запуска: `claude-cc-bin` volume прогревается обёрткой `ccd` автоматически, при первом старте CC внутри контейнера инициирует OAuth-flow.

## Референс

`<setup>/lib/project-template/` — обезличенная папка-эталон проектной директории. Имя проекта в шаблоне — `expro` (example project). Содержимое:

| Файл | Назначение |
|---|---|
| `init.sh` | полный пример проектного init.sh: образ `cc-image-expro` (FROM `cc-image`), сервисный `cc-expro-vpn-image` (FROM `debian:bookworm-slim`), копирование xray-конфига в `vpn-config/` (chmod 600), генерация `db-credentials.env` и `ccd-config.sh` без перезаписи, `docker create` для `cc-expro-vpn`, каскад флагов `--rebuild` / `--rebuild-base-derived` |
| `Dockerfile` | минимальный `FROM cc-image` с закомментированными примерами расширений (postgres-client, Playwright). Удалить, если проекту достаточно базового `cc-image` |
| `Dockerfile.vpn` | сервисный xray + socat. Копируется в проект без изменений; вся специфика — в `vpn-config/config.json` + ENV `DB_REMOTE_HOST`/`DB_REMOTE_PORT` |
| `vpn-entrypoint.sh` | entrypoint VPN-контейнера. Копируется без изменений |
| `mcp.json` | пустой `{"mcpServers": {}}`. Заполняется руками или генерируется проектным init.sh |

Прочитать `init.sh` целиком — самый быстрый способ понять структуру. Адаптация: скопировать всю папку (или нужные файлы) в `<setup>/<project-name>/`, заменить `expro` → `<project-name>` (в т.ч. ENV-префикс `EXPRO_*`), скорректировать `COMPOSE_NETWORKS` и `DB_REMOTE_HOST`, удалить блоки VPN/credentials, если они не нужны.

`vpn-config/config.json` шаблон НЕ содержит — это секрет. Два рабочих пути:
1. **Источник истины — в проекте**: положить `xray-config.json` в `<projects-root>/<project-name>/xray-config.json` (так делает шаблон `init.sh`, секция 2). При первом запуске `init.sh` скопирует его в `<setup>/<project-name>/vpn-config/config.json` (chmod 600). Удобно, если xray-конфиг уже в репо проекта (с правильным `.gitignore`!) или у пользователя на руках.
2. **Источник истины — в setup-папке**: положить `config.json` сразу в `<setup>/<project-name>/vpn-config/config.json` руками (chmod 600). `init.sh` увидит файл и пропустит копирование. Удобно, если хочется держать секрет полностью вне репо проекта.

В обоих случаях после первого запуска `init.sh` истиной становится `<setup>/<project-name>/vpn-config/config.json` (он же монтируется в VPN-контейнер read-only). Ротация — правка этого файла + `docker restart cc-<project-name>-vpn`.
