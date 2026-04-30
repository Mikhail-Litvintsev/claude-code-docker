# Claude Code Docker

Обёртка для запуска [Claude Code](https://docs.anthropic.com/en/docs/claude-code) в Docker-контейнерах, изолированных по проектам. Один OAuth-токен на хост, отдельный контейнер на каждую сессию, прозрачная интеграция с проектными compose-сетями и сервисными контейнерами (VPN, прокси и т.п.).

Тестировалось на **Ubuntu 22.04+**. Хостовый `claude` не обязателен — `ccd` запускает изолированный экземпляр CC из docker-volume `claude-cc-bin`.

---

## Зачем

- **`--dangerously-skip-permissions` без риска.** CC работает без подтверждений `Bash`/`Edit`/`Write`; защита держится не на prompt'ах, а на изоляции уровня контейнера: docker API через прокси с whitelist'ом, `--cap-drop=ALL` + `no-new-privileges`, sanitized git-identity, нет доступа к `~/.ssh/`, `~/.aws/`, `~/.bashrc` хоста.
- **Один контейнер — один проект.** Bind-mount только своей папки.
- **Подключение к compose-сетям.** Внутри сессии видны `db`, `redis` и т.п. по compose-именам.
- **Общий OAuth-токен.** OAuth — один раз, в volume `claude-auth`, переиспользуется всеми проектами.
- **Идемпотентный bootstrap.** `init.sh` можно перезапускать сколько угодно — повторный прогон ничего не пересобирает.

---

## Архитектура

```
<setup>/                                    setup-репозиторий
├── Dockerfile, init.sh, connect-project.md
├── bin/ccd                                 обёртка-запускалка
├── cc-docker-proxy/haproxy.cfg             whitelist docker API
├── lib/init-helpers.sh, project-template/  helpers + шаблон проекта
└── <project-name>/                         настройки проекта (НЕ в репо)
    ├── init.sh                             проектный инициализатор
    ├── ccd-config.sh                       сгенерируется (вне bind-mount проекта — анти-tampering)
    ├── mcp.json                            project-level MCP
    ├── Dockerfile (опц.) FROM cc-image
    └── Dockerfile.<svc> + <svc>-config/ (опц.) сервисные контейнеры

<projects-root>/<project-name>/             код проекта (отдельный репо)
└── .claude/{<name>-credentials.env, scripts/}
```

| Ресурс | Назначение |
|---|---|
| `cc-image` | базовый образ (FROM `node:22-slim` + git/curl/jq/rg/docker-cli) |
| `cc-image-<project>` | (опц.) проектное расширение |
| `cc-net` | docker-сеть для сервисных контейнеров |
| `cc-docker-proxy` | прокси docker.sock с whitelist'ом |
| `claude-auth` (volume) | OAuth-токен, общий |
| `claude-cc-bin` (volume) | бинарь Claude Code, прогревается `ccd` |
| `cc-<project>-<pid>` | временный контейнер на сессию (`--rm`) |
| `cc-<project>-<svc>` | сервисный контейнер (refcount управляет `ccd`) |

---

## Требования

- Linux (Ubuntu 22.04 / 24.04).
- Docker Engine 20.10+ с плагином Docker Compose v2.
- `jq`, `flock` (`util-linux`), `realpath` (`coreutils`).
- Пользователь в группе `docker`.

`init.sh` сам проверяет утилиты и падает с подсказкой при отсутствии.

---

## Установка

```bash
cd ~/projects   # либо другой <projects-root>
git clone <repo-url> claude-code-docker
bash claude-code-docker/init.sh
source ~/.bashrc   # для нового PATH
```

`init.sh` создаёт `cc-net`/`claude-auth`/`cc-docker-proxy`, собирает `cc-image` под UID/GID хоста, дописывает `<setup>/bin` в PATH, запускает `<setup>/*/init.sh` для подключённых проектов.

**Авторизация Claude Code (один раз):**

```bash
cd <projects-root>/<любой-проект>
ccd
```

Первый запуск прогревает `claude-cc-bin` (~30 сек), CC внутри инициирует OAuth-flow. Если auto-prompt не сработал — внутри сессии `/login`. Токен живёт в `claude-auth` для всех проектов.

---

## Использование

```bash
cd <projects-root>/<project-name>
ccd                       # интерактивная CC-сессия
ccd -- <claude-flag>      # передача флагов в claude CLI
```

`ccd` walks вверх от `$PWD` до предка с `<setup>/<basename>/ccd-config.sh`, читает конфиг, стартует сервисные контейнеры под refcount, запускает CC-контейнер с bind-mount проекта и compose-сетями. На выходе — `--rm` + cleanup сервисных по refcount.

---

## Подключение нового проекта

`connect-project.md` — ТЗ для агента Claude (запускать в нативном `claude` на хосте). Если нативного нет — пройти руками, отталкиваясь от `lib/project-template/`.

**Краткая последовательность:**

1. Создать пару `<setup>/<name>/` + `<projects-root>/<name>/` (одинаковое имя).
2. Скопировать нужные файлы из `lib/project-template/` в `<setup>/<name>/`, заменить `expro` → `<name>`.
3. `bash <setup>/init.sh --project <name>`.
4. `cd <projects-root>/<name> && ccd` — внутри сессии должны быть видны проектные сервисы.

`<setup>/<project-name>/` исключена whitelist'ом из setup-репозитория — содержит секреты.

---

## Идемпотентность и пересборка

`init.sh` идемпотентен — `inspect → SKIP / create` для каждого ресурса.

| Флаг | Действие |
|---|---|
| `--rebuild` | пересобрать ВСЕ образы (общие + проектные + сервисные) |
| `--skip-projects` | только общие шаги |
| `--project <name>` | только указанный проектный init.sh |

При расхождении UID/GID хоста с `cc-image` корневой `init.sh` пересобирает `cc-image` и передаёт `--rebuild-base-derived` проектным — пересобираются только производные `FROM cc-image`.

---

## Конфигурация проектного `ccd-config.sh`

Bash-файл с переменными для обёртки `ccd`. Лежит в `<setup>/<project>/`, **не** в bind-mount'е проекта — иначе CC изнутри сессии мог бы переписать `EXPOSE_GIT_PUSH=0` → `1`. Изменения подхватываются новой сессией.

### Базовые переменные

| Переменная | Тип | Назначение |
|---|---|---|
| `IMAGE` | string | Образ CC-контейнера: `cc-image-<project>` или `cc-image`. |
| `CONTAINER_NAME_PREFIX` | string | Префикс имён CC-контейнеров (финальное — `<prefix>-<pid>`). |
| `COMPOSE_NETWORKS` | bash array | Список compose-сетей. Пустой `()` — без подключения. |
| `VPN_CONTAINER` | string | Имя VPN-контейнера. `""` — VPN не используется. |
| `VPN_REFCOUNT_FILE` | path | Файл refcount активных сессий, держащих VPN. |

### Защита от git-RCE

| Переменная | Default | Что делает | Что ломает |
|---|---|---|---|
| `LOCK_GIT_INTERNALS` | `1` | bind-mount `.git/hooks` и `.git/config` всех `.git`-директорий проекта (`maxdepth 4`) как `:ro`. CC не может писать вредоносный hook или per-repo `[alias] !cmd`/`[core] sshCommand`/`[filter "X"]`. | `git config --local`, `pre-commit install`/`husky install` изнутри сессии. |
| `LOCK_GITMODULES` | `0` | bind-mount `.gitmodules` как `:ro`. CC не может подменить URL подмодуля. | `git submodule add` изнутри сессии. |

Audit (всегда): sha256-snapshot `.git/hooks/*`, `.git/config`, `.gitattributes`, `.gitmodules` фиксируется при старте, сравнивается на cleanup; расхождение → stderr WARNING.

Что **не** закрывается флагами: локальные мутации истории (`rebase`, `reset --hard`, `commit --amend`, `filter-branch`) — это легитимное использование git. Митигация — `git fetch` + `git log -p` в чистом remote перед push.

### Git-доступ (опт-ин)

| Переменная | Default | Что пробрасывается | Риск |
|---|---|---|---|
| `EXPOSE_GIT_IDENTITY` | `1` | sanitized `~/.gitconfig` + `[includeIf]`-includes как `:ro` — `git commit` с нормальным cascade | минимальный |
| `EXPOSE_GIT_PUSH` | `0` | `$SSH_AUTH_SOCK` — `git push` через ВСЕ ключи в ssh-agent | средний |
| `EXPOSE_GITCONFIG` | `0` | raw `~/.gitconfig` без sanitize — `signingkey`, `credential.helper`, `[url]`-rewrites | высокий |

При `EXPOSE_GIT_IDENTITY=1` из global gitconfig вырезаются: `[credential]`, `[gpg]`, `[http]`, `[https]`, все `[url "..."]`, `*.signingkey`, `core.sshCommand`/`askpass`/`hooksPath`, `commit.gpgsign`/`tag.gpgsign`. Сохраняются: `user.name`, `user.email`, `pull.*`, `merge.*`, `rebase.*`, `alias.*`, `[includeIf]`.

| Сценарий | `IDENTITY` | `PUSH` | `GITCONFIG` | Когда |
|---|---|---|---|---|
| Read-only анализ | `0` | `0` | `0` | Чужой код, untrusted PR. |
| **CC коммитит, юзер пушит** | `1` | `0` | `0` | **Default из шаблона.** |
| Полная свобода | `1` | `1` | `0` | Доверенный личный проект. |
| Особый gitconfig | — | — | `1` | GPG-signed commits, кастомные `[url]`-rewrites. |

Незаданный `EXPOSE_*` = `0` (fail-secure). Незаданный `LOCK_GIT_INTERNALS` = `1` (fail-secure).

XDG-альтернатива (`~/.config/git/config`) **не поддерживается** — `bin/ccd` читает только `~/.gitconfig`. Мигрируйте либо настройте per-repo через `git config --local`.

---

## MCP-серверы

Project-MCP конфиг — `<setup>/<project>/mcp.json` (вне bind-mount'а — анти-tampering). `ccd` запускает `claude --mcp-config <path> --strict-mcp-config`: остальные источники (`.mcp.json` в проекте, `~/.claude.json` `projects[].mcpServers`) игнорируются.

```json
{
  "mcpServers": {
    "playwright": {
      "type": "stdio",
      "command": "npx",
      "args": ["@playwright/mcp@latest", "--browser=chromium"]
    }
  }
}
```

IDE-MCP (PhpStorm и т.п.) подключается отдельно — через bind-mount IDE-lock-файла + `CLAUDE_CODE_SSE_PORT`.

---

## Безопасность

CC работает с `--dangerously-skip-permissions`. Изоляция:

1. **Прокси docker.sock** (`tecnativa/docker-socket-proxy` + custom `haproxy.cfg`). Разрешено: `containers/exec`/`start`/`stop`/`inspect`, `networks/inspect`. Запрещено: `containers/create` (explicit deny в `haproxy.cfg`), `build`, `images/pull`, `volumes/*`. Атакующий не может создать `--privileged` контейнер.
2. **`--cap-drop=ALL`** + `--security-opt=no-new-privileges`.
3. **Опт-ин git-доступ** через `EXPOSE_GIT_*` (default `1/0/0`).
4. **`LOCK_GIT_INTERNALS=1`** (default) — `.git/hooks/*` и per-repo `.git/config` смонтированы `:ro`, git-RCE векторы закрыты.

**Что атакующий через prompt injection может:**
- Изменить файлы проекта (откатываемо через git).
- Прочитать OAuth-token из `claude-auth` и отправить наружу (`claude /logout` + повторная авторизация).
- `docker compose exec` в compose-контейнер проекта — команда с правами того контейнера, **не** хоста.
- Дойти до соседних compose-стеков через подключённые сети.

**НЕ может:**
- Прочитать `~/.ssh/`, `~/.aws/`, `~/.config/` хоста.
- Изменить `~/.bashrc`/`authorized_keys`/cron.
- Эскалировать до root через docker.sock.
- Записать вредоносный `.git/hooks/<name>` или `[alias] !cmd`/`[core] sshCommand` в per-repo `.git/config` (при `LOCK_GIT_INTERNALS=1`).

**Когда модель ломается:**
- `EXPOSE_GIT_PUSH=1` или `EXPOSE_GITCONFIG=1` — агент получает ssh-agent / raw gitconfig.
- `LOCK_GIT_INTERNALS=0` — открываются git-RCE векторы (`.git/hooks/`, per-repo `[alias]`/`sshCommand`/`[filter]`).
- `-v /var/run/docker.sock:...` в проектном Dockerfile или публикация TCP-порта прокси (`-p 2375:2375`).

Для **полной** изоляции от compose-контейнеров проекта (untrusted код) — отдельная VM либо rootless Docker.

---

## Troubleshooting

| Симптом | Решение |
|---|---|
| `[FAIL] не найден 'docker'` | установите Docker Engine, в группу `docker`, перезайдите. |
| `[FAIL] не работает 'docker compose'` | `apt install docker-compose-plugin`. |
| Файлы как `nobody:nogroup` после `ccd` | UID/GID не совпадает — `bash init.sh` пересоберёт `cc-image`. |
| OAuth-flow не стартует | внутри сессии `/login`. |
| `cc-<project>-vpn` не стартует | `docker logs cc-<project>-vpn`, проверить `<setup>/<project>/vpn-config/`. |

---

## Лицензия

См. `LICENSE` либо обратитесь к владельцу репозитория.
