# ci-cd.yml — сборка, релиз, публикация и деплой

Один workflow закрывает весь путь от пуша до сервера: собирает проект (на нескольких ОС),
создаёт GitHub Release, публикует пакет (npm / Docker / Packagist) и деплоит. Всё настраивается
**переменными и секретами репозитория**, YAML менять не нужно.

Файл логики: [.github/workflows/ci-cd.yml](../../../.github/workflows/ci-cd.yml) ·
шаблон для копирования: `.github/workflow-templates/ci-cd.yml`

---

## Быстрый старт

1. Скопируй `.github/workflow-templates/ci-cd.yml` в `.github/workflows/` своего проекта.
2. Создай **Environment** с именем своей ветки (Settings → Environments → New environment,
   например `main`).
3. Задай в этом Environment переменные. Минимум для «просто прогонять тесты»:
   ```
   ACTION_TRIGGER=PUSH
   CI_COMMAND=npm test
   ```
4. Запушь — workflow запустится сам.

Любая незаданная переменная просто выключает свой шаг, а джоба становится **серой (skipped)**, а не
красной. Красный статус = реальная ошибка команды.

---

## Где задавать переменные и секреты

Всё берётся из **GitHub Environments** (Settings → Environments → выбрать окружение):

- **Variables** — обычные значения (`vars.*`). Все переменные из таблиц ниже — отсюда.
- **Secrets** — чувствительные значения (`secrets.*`): ключи, токены, пароли.

Имя Environment вычисляется автоматически:

| Событие | Имя Environment |
|---|---|
| push ветки, ручной запуск на ветке | имя ветки |
| `pull_request` | имя **целевой** ветки (куда PR) |
| push тега `vX.Y.Z` | ветка, определённая по коммиту тега |
| push тега `{branch}/vX.Y.Z` | `{branch}` из тега (ветка обязана существовать) |
| задан вход `environment` | значение входа, приоритетнее всего |

Слеши заменяются на дефис: ветке `release/1.x` соответствует Environment `release-1.x`.

Разные окружения = разные настройки: можно собирать `main` под npm, а `develop` — только тесты.

> **Исключение:** `MULTIPLE_PACKAGES` задаётся **на уровне репозитория**
> (Settings → Secrets and variables → Actions → Variables), а не в Environment — она читается
> ещё до того, как окружение выбрано.

---

## Что и когда запускать

| Переменная | По умолчанию | Значения / смысл |
|---|---|---|
| `ACTION_TRIGGER` | `WORKFLOW_DISPATCH` | Когда пайплайн «активен»: `WORKFLOW_DISPATCH` / `PUSH` / `RELEASE`. Любое другое значение — ошибка. Устаревшее `DISPATCH` принимается с предупреждением |

| `ACTION_TRIGGER` | Событие | ci | release | cd |
|---|---|:--:|:--:|:--:|
| `WORKFLOW_DISPATCH` (по умолчанию) | push ветки/тега | — | — | — |
| `WORKFLOW_DISPATCH` | ручной запуск на ветке | ✔ | — | ✔ |
| `WORKFLOW_DISPATCH` | ручной запуск на теге | ✔ | ✔ | ✔ |
| `PUSH` | push ветки | ✔ | — | ✔ |
| `PUSH` | push тега | ✔ | ✔ | ✔ |
| `RELEASE` | push ветки | — | — | — |
| `RELEASE` | push тега | ✔ | ✔ | ✔ |
| любой | pull request | ✔ | — | — |

Дополнительные условия поверх таблицы:

- `ci` запускается, только если задана `BUILD_COMMAND` **или** `CI_COMMAND`.
- `release` возможен только на теге — без тега публиковать нечего.
- `cd` запускается, только если заданы **все четыре**: `DEPLOY_HOST` + `DEPLOY_USER` +
  `DEPLOY_PATH` + секрет `DEPLOY_KEY`. И никогда — на pull request.

---

## Ручной запуск: входы

Actions → **ci/cd** → **Run workflow**. В **Use workflow from** выбирается ветка **или тег**
(релиз возможен только при выборе тега).

| Вход | Тип | По умолчанию | Что делает |
|---|---|---|---|
| `run_ci` | галочка | вкл | Снять — пропустить сборку и тесты |
| `run_release` | галочка | вкл | Снять — не трогать Release и реестры |
| `run_cd` | галочка | вкл | Снять — не деплоить |
| `environment` | строка | пусто | Задать окружение вручную (переопределяет автоопределение) |
| `runs_on` | строка | пусто | Переопределить `RUNS_ON` на этот запуск |
| `publish_method` | список | пусто | Переопределить `PUBLISH_METHOD` |
| `commits` | строка | пусто | Коммиты через запятую → выборочный деплой |
| `deploy_mirror` | список | `false` | `false` / `true` / `full` на этот запуск |

Галочки только **снимают** флаг: если `ACTION_TRIGGER` не разрешает деплой, включённая `run_cd`
его не добавит.

**Переопубликовать тег** (публикация упала / Trusted Publisher настроили позже): Run workflow,
в **Use workflow from** выбрать тег, снять `run_ci` и `run_cd` — пойдёт только релиз и публикация.
Повтор безопасен: уже опубликованные версии пропускаются.

---

## Переменные

### Сборка и проверки (`ci`)

| Переменная | По умолчанию | Смысл |
|---|---|---|
| `BUILD_COMMAND` | пусто | Команда сборки. Пусто → шаг пропускается. Пример: `npm ci && npm run build` |
| `CI_COMMAND` | пусто | Команда проверок/тестов. Пусто → шаг пропускается. Пример: `npm test` |
| `RUNS_ON` | `ubuntu-latest` | ОС сборки через запятую: `ubuntu-latest,windows-latest,macos-latest`. Пустой список → ошибка |
| `TOOLCHAIN` | пусто | Языки и версии через запятую: `node:24,python:3.12`. Пусто → версии, предустановленные на runner'е |

### Релиз (`release-publish`)

| Переменная | По умолчанию | Смысл |
|---|---|---|
| `RELEASE_FILES` | пусто | Файлы для прикрепления к Release; glob'ы через запятую: `dist/*.zip,bin/app-*`. Пусто → Release создаётся без ассетов |
| `PUBLISH_METHOD` | пусто | Куда публиковать после релиза: `npm` / `docker` / `packagist`. Пусто → не публиковать. Неизвестное значение → предупреждение, публикации не будет |
| `MULTIPLE_PACKAGES` | `false` | **repository-level.** `true` → отдельный пакет/образ на каждую ветку, тег обязан быть вида `{branch}/vX.Y.Z` |

### Публикация Docker (при `PUBLISH_METHOD=docker`)

| Переменная | По умолчанию | Смысл |
|---|---|---|
| `DOCKER_REGISTRY` | `ghcr.io` | Реестр |
| `DOCKER_IMAGE` | `<owner>/<repo>` | Имя образа без реестра |
| `DOCKERFILE_PATH` | `./Dockerfile` | Путь к Dockerfile. Файла нет → джоба падает |
| `BUILD_CONTEXT` | `.` | Контекст сборки. Результаты `ci` распаковываются в корень рабочего каталога, а не сюда |
| `DOCKER_USERNAME` | `github.actor` | Логин реестра (для `ghcr.io` не нужен) |
| `DOCKER_BUILD_ARGS` | пусто | Доп. build-args, по одному на строку |

### Публикация Packagist (при `PUBLISH_METHOD=packagist`)

| Переменная | По умолчанию | Смысл |
|---|---|---|
| `PACKAGIST_USERNAME` | — | Имя пользователя Packagist |

### Деплой (`cd`)

| Переменная | По умолчанию | Смысл |
|---|---|---|
| `DEPLOY_METHOD` | `COMMAND` | `COMMAND` / `FTP` / `RSYNC` / `GIT` — см. раздел про режимы |
| `DEPLOY_HOST` | — | Хост сервера. **Обязателен для деплоя** |
| `DEPLOY_USER` | — | Пользователь. **Обязателен** |
| `DEPLOY_PATH` | — | Каталог на сервере. **Обязателен** |
| `DEPLOY_PORT` | `22` | Порт SSH / FTP |
| `DEPLOY_LOCAL_DIR` | `./` | Локальный каталог-источник: что именно заливать |
| `DEPLOY_MIRROR` | `false` | `false` / `true` / `full` — см. ниже. ⚠️ через workflow-шаблон эта переменная не действует, см. «Особые случаи» |
| `DEPLOY_LAST_COMMITS` | `false` | `true` → на push деплоить только файлы этого push (выборочный режим) |
| `BEFORE_DEPLOY_COMMAND` | пусто | Команда по SSH **до** деплоя. Не выполняется при `DEPLOY_METHOD=FTP`. Пример: `php artisan down` |
| `AFTER_DEPLOY_COMMAND` | пусто | Команда по SSH **после** деплоя. Не выполняется при `DEPLOY_METHOD=FTP`. Пример: `docker compose pull && docker compose up -d` |

### Секреты

| Секрет | Где нужен | Смысл |
|---|---|---|
| `GITHUB_TOKEN` | всегда | Встроенный, задавать не надо. Release, GitHub Packages, `ghcr.io` |
| `DEPLOY_KEY` | cd | Приватный SSH-ключ; для `DEPLOY_METHOD=FTP` — пароль |
| `DOCKER_TOKEN` | docker | Пароль реестра (для `ghcr.io` не нужен — подставится `GITHUB_TOKEN`) |
| `PAT_TOKEN` | docker | Пробрасывается в образ как build-arg `GH_TOKEN` (если на сборке нужен приватный доступ) |
| `PACKAGIST_API_TOKEN` | packagist | Токен Packagist; для **первой** публикации нужен MAIN-токен |

> Токен npmjs **не нужен**: публикация идёт через OIDC trusted publishing.

---

## Сборка под несколько ОС

`RUNS_ON=ubuntu-latest,windows-latest` → сборка идёт на обеих, в Release попадут артефакты обеих.

В `BUILD_COMMAND` доступны:
- `$RUNNER_OS` — `Linux` / `Windows` / `macOS`;
- `$MATRIX_OS` — `ubuntu-latest` / `windows-latest` / …

Имена результатов **должны различаться по ОС**, иначе они перезапишут друг друга при слиянии:
```
BUILD_COMMAND=pyinstaller --onefile --name "app-$RUNNER_OS" main.py
RELEASE_FILES=dist/app-*
```

Сборка должна писать в **обычный** каталог (`dist/`, `build/`): скрытые пути (`.next`, `.output`,
`.git`, `.env`, `.npmrc`) дальше `ci` не передаются.

При нескольких ОС имя чека становится `ci (ubuntu-latest)`, а не `ci` — это важно для правил
branch protection.

---

## TOOLCHAIN: языки и версии

Формат `<инструмент><разделитель><версия>` через запятую. Разделитель — `:` или `@`. Версию можно
опустить — будет `latest`.

```
TOOLCHAIN=node:24
TOOLCHAIN=node@24,python@3.12
TOOLCHAIN=go:1.23,php:8.3
```

Список открытый: node, python, go, php, java, ruby, rust, bun, deno, terraform и сотни других.
Добавить язык = дописать в переменную. Пусто → используются версии, предустановленные на runner'е.

При `PUBLISH_METHOD=npm` версия node для публикации берётся из `TOOLCHAIN`; если node там не
указан — используется `lts/*`.

---

## Формат тега

Определяется repository-level переменной `MULTIPLE_PACKAGES`:

- **`false` (по умолчанию)** — тег плоский: `v1.2.3`. Ветку (Environment) workflow определяет сам,
  по коммиту тега. Тег с префиксом ветки → ошибка.
- **`true`** — тег с явной веткой: `main/v1.2.3`. Ветка берётся из префикса и обязана существовать;
  имя пакета/образа получает суффикс (`@owner/name-main`, `owner/repo-main`). Тег без префикса → ошибка.

Допустимы `v#`, `v#.#`, `v#.#.#`. Недостающие части версии дополняются нулями: `v1` → `1.0.0`.

```
git tag v1.0.0 && git push origin v1.0.0
# либо при MULTIPLE_PACKAGES=true:
git tag main/v1.0.0 && git push origin main/v1.0.0
```

---

## Настройка публикации

### npm (`PUBLISH_METHOD=npm`)

Пакет уходит в **оба** реестра:

- **GitHub Packages** — обязательный шаг, по `GITHUB_TOKEN`, настраивать нечего;
- **npmjs.org** — по OIDC, шаг помечен `continue-on-error`: его падение не валит пайплайн.

Для npmjs токен не нужен, но один раз настрой **Trusted Publisher**: npmjs.com → Package Settings →
Trusted Publisher → GitHub Actions → владелец, репозиторий, имя workflow-файла **`ci-cd.yml`**,
environment оставить пустым.

Требования и нюансы:

- Имя в `package.json` scoped и совпадает с владельцем: `@owner/name`.
- Закоммиченный `.npmrc` удаляется перед публикацией — но лучше вообще не коммитить его с токенами.
- Версия пакета берётся из тега, `package.json` при этом не коммитится обратно.
- Приватный репозиторий → публикация с `--access restricted`, публичный → `--access public`.
- Уже существующая в реестре версия пропускается (повторный запуск безопасен).
- Для самого первого публиша нового имени на npmjs — опубликуй разово вручную токеном, потом
  включай Trusted Publisher.
- Вызывающему workflow нужны права `id-token: write` — в шаблоне они уже есть, не удаляй.

### docker (`PUBLISH_METHOD=docker`)

Нужен `Dockerfile`. Результаты `ci` уже распакованы поверх checkout'а в корень рабочего каталога,
поэтому в образе достаточно `COPY dist/ /app/` без пересборки. Для `ghcr.io` секреты не нужны.

Пути в `DOCKERFILE_PATH` и `BUILD_CONTEXT` считаются от корня рабочего каталога, а сгенерированный
на шаге `ci` каталог сборки лежит там же, где его оставила `BUILD_COMMAND`.

Скрытые файлы в артефакт попадают: шаг выгрузки поднимает `include-hidden-files`, иначе
`.dockerignore` и `.env.example` терялись бы по дороге. Исключён только `.git`. Учтите обратную
сторону: артефакт доступен любому, у кого есть чтение репозитория, поэтому всё, что `BUILD_COMMAND`
создаёт в рабочем каталоге — включая `.env` с ключами, — уедет туда вместе с остальным.

Образ пушится с тегами:

| Тег | Когда |
|---|---|
| `<registry>/<image><суффикс>:<версия>` | всегда |
| `…:latest` | всегда |
| `…:<ветка>` | только при `MULTIPLE_PACKAGES=false` |

Имя образа приводится к нижнему регистру. Платформа фиксирована: `linux/amd64`.
В сборку всегда передаются build-args `GH_TOKEN` (из секрета `PAT_TOKEN`), `VERSION` (короткий SHA)
и `ENVIRONMENT` (имя окружения); `DOCKER_BUILD_ARGS` добавляется сверху.

```
PUBLISH_METHOD=docker
DOCKER_IMAGE=myorg/myapp             # опционально
DOCKERFILE_PATH=./docker/Dockerfile  # опционально
```

### packagist (`PUBLISH_METHOD=packagist`)

```
PUBLISH_METHOD=packagist
PACKAGIST_USERNAME=<user>
# secret: PACKAGIST_API_TOKEN
```

Сначала выполняется обновление пакета; если пакета ещё нет (HTTP 404) — предпринимается попытка его
создать, и для неё нужен **MAIN** API-токен Packagist, обычного update-токена не хватит.

---

## Режимы деплоя

### DEPLOY_METHOD

| Значение | Что делает |
|---|---|
| `COMMAND` (по умолчанию) | Файлы **не передаются**. Выполняются только `BEFORE_/AFTER_DEPLOY_COMMAND` по SSH. `DEPLOY_KEY` всё равно обязателен |
| `RSYNC` | Заливка по rsync поверх SSH, с 3 повторами при сбое |
| `FTP` | Заливка через lftp; при сбое пакетной операции — повтор пофайлово. `BEFORE_/AFTER_DEPLOY_COMMAND` **не выполняются** |
| `GIT` | Сервер сам делает `clone` / `pull`. Требует доступа сервера к репозиторию по SSH (`git@github.com:…`) |

### Что заливается (scope)

Выбирается автоматически:

| Условие | Что заливается |
|---|---|
| `DEPLOY_METHOD=COMMAND` | ничего, только SSH-команды |
| push тега; push при `DEPLOY_LAST_COMMITS=false`; ручной запуск без `commits` | **полный** — весь `DEPLOY_LOCAL_DIR` |
| push при `DEPLOY_LAST_COMMITS=true`; ручной запуск с `commits` | **выборочный** — только файлы, затронутые в этих коммитах |

### DEPLOY_MIRROR

| Значение | Полный режим | Выборочный режим |
|---|---|---|
| `false` | ничего не удаляется | ничего не удаляется |
| `true` | ничего не удаляется | удаляются файлы, убранные в задеплоенных коммитах |
| `full` | точное зеркало: **всё лишнее на сервере удаляется** | ❌ запрещено, джоба падает |

Для `DEPLOY_METHOD=GIT` значение `full` означает `fetch` + `reset --hard`: любые локальные правки
на сервере будут затёрты. Остальные значения — обычный `git pull`.

### Что никогда не передаётся

- При `DEPLOY_MIRROR=false` исключается всё, что начинается с `.git` — включая `.gitignore`,
  `.gitattributes`, `.gitmodules`.
- При `DEPLOY_MIRROR=true` / `full` исключаются только `.git` и `.github` — то есть `.gitignore`
  и подобные файлы **уедут на сервер**.

---

## Особые случаи

**`DEPLOY_MIRROR` не работает через workflow-шаблон.** Шаблон всегда прокидывает вход
`deploy_mirror` (его значение по умолчанию — строка `false`), а вход приоритетнее переменной.
Поэтому `vars.DEPLOY_MIRROR` при вызове через шаблон не читается никогда. Варианты:

- задать зеркалирование разово через Actions → Run workflow → `deploy_mirror`;
- либо поменять `default:` у входа `deploy_mirror` в своей копии шаблона.

**Результаты сборки деплоятся только в полном режиме.** В выборочном режиме список файлов строится
из git-истории, а собранных файлов в git нет; вдобавок дерево переводится на нужный коммит. Поэтому
артефакт `ci` там не распаковывается — вместо него на раннере заново выполняется `BUILD_COMMAND`
(с установкой `TOOLCHAIN`), а в лог пишется предупреждение.

**Запрещённые сочетания** — джоба падает с явным сообщением:

- `DEPLOY_METHOD=GIT` + выборочный режим: `GIT` тянет ветку целиком, а не подмножество файлов.
- `DEPLOY_MIRROR=full` + выборочный режим: `full` — это зеркало всего дерева. Для удаления файлов,
  убранных в задеплоенных коммитах, есть `DEPLOY_MIRROR=true`.
- `DEPLOY_MIRROR` со значением вне `false | true | full`.

**Release создаётся всегда**, когда `run_release=true` — даже при пустом `RELEASE_FILES`
(просто без ассетов). Но если `RELEASE_FILES` задан и ни один glob ничего не нашёл — джоба падает.

**Порядок джоб.** Деплой ждёт релиз и все публикации, поэтому `docker compose pull` в
`AFTER_DEPLOY_COMMAND` не выполнится раньше, чем образ запушен. Пропущенные (серые) джобы деплой
не блокируют.

**Имена файлов в Release уплощаются**: `/` в пути заменяется на `__`, чтобы файлы из разных
каталогов не конфликтовали:
```
dist/linux/app        →  linux__app
dist/windows/app.exe  →  windows__app.exe
```

---

## Примеры конфигураций

**Тесты + автодеплой по rsync на каждый push:**
```
ACTION_TRIGGER=PUSH
TOOLCHAIN=node:24
BUILD_COMMAND=npm ci && npm run build
CI_COMMAND=npm test
DEPLOY_METHOD=RSYNC
DEPLOY_HOST=example.com
DEPLOY_USER=deploy
DEPLOY_PATH=/var/www/project
DEPLOY_LOCAL_DIR=dist/
AFTER_DEPLOY_COMMAND=php artisan migrate && php artisan up
# secret: DEPLOY_KEY
```

**Бинарники Linux + Windows в Release:**
```
ACTION_TRIGGER=RELEASE
RUNS_ON=ubuntu-latest,windows-latest
TOOLCHAIN=python:3.12
BUILD_COMMAND=pip install pyinstaller && pyinstaller --onefile --name "app-$RUNNER_OS" main.py
RELEASE_FILES=dist/app-*
```

**Docker-образ из собранного + деплой командой:**
```
ACTION_TRIGGER=RELEASE
TOOLCHAIN=node:24
BUILD_COMMAND=npm ci && npm run build
PUBLISH_METHOD=docker
DEPLOY_METHOD=COMMAND
DEPLOY_HOST=example.com
DEPLOY_USER=deploy
DEPLOY_PATH=/srv/app
AFTER_DEPLOY_COMMAND=docker compose pull && docker compose up -d
# secret: DEPLOY_KEY
```

**Только релиз с публикацией в npm (без деплоя):**
```
ACTION_TRIGGER=RELEASE
TOOLCHAIN=node:24
BUILD_COMMAND=npm ci && npm run build
PUBLISH_METHOD=npm
# DEPLOY_* не заданы → cd серая
```

---

## Если что-то не запускается

- **Всё серое.** Смотри лог джобы `resolve-config`: там печатаются `ACTION_TRIGGER`, событие и
  итоговые `run_ci / run_release / run_cd`. Чаще всего `ACTION_TRIGGER` не тот.
- **`ci` серая.** Не заданы ни `BUILD_COMMAND`, ни `CI_COMMAND`.
- **`cd` серая при `ACTION_TRIGGER=PUSH`.** Заданы не все из `DEPLOY_HOST` / `DEPLOY_USER` /
  `DEPLOY_PATH` + секрет `DEPLOY_KEY`.
- **Переменные не подхватываются.** Они заданы не в том Environment: имя окружения печатается в
  логе `resolve-branch` (`Environment resolved to: …`).
- **Ошибка на формате тега.** Тег не соответствует режиму `MULTIPLE_PACKAGES` — в сообщении указано,
  какая форма ожидается.
- **`Branch '...' from tag not found`.** В теге `{branch}/vX.Y.Z` указана несуществующая ветка.
- **Файлы не попали в Release.** Проверь `RELEASE_FILES`; собранных файлов нет в дереве, если `ci`
  не запускалась (`run_ci=false`).
- **Собранное не доехало до сервера.** Сработал выборочный режим деплоя — см. предупреждение в логе
  `cd`; результаты сборки деплоятся только в полном режиме.
- **Зеркалирование не сработало.** См. «Особые случаи»: `vars.DEPLOY_MIRROR` не действует при вызове
  через шаблон.
- **`BEFORE_/AFTER_DEPLOY_COMMAND` не выполнились.** Стоит `DEPLOY_METHOD=FTP` — для него эти шаги
  отключены.
- **PR не разблокируется.** При нескольких ОС имя чека — `ci (ubuntu-latest)`, а не `ci`; обнови
  требуемые чеки в branch protection.
- **npm `401` (GitHub Packages).** Имя пакета должно быть scoped и совпадать с владельцем; в
  репозитории не должно быть закоммиченного `.npmrc`.
- **npm OIDC падает.** Не настроен Trusted Publisher, либо в нём осталось старое имя файла, либо
  пакета ещё нет на npmjs. Пайплайн при этом не падает — шаг помечен `continue-on-error`.
- **Packagist: `create failed`.** Для первой публикации нужен MAIN API-токен, а не update-токен.
- **«уже есть — пропускаем».** Не ошибка: версия уже опубликована. Нужен новый тег.
