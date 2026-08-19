# Reusable workflows — git_toolkit

Здесь лежат **тонкие workflow-шаблоны** для реальных проектов. Вся логика живёт в
`cat-of-summer/git_toolkit/.github/workflows/*.yml` и подключается как
[reusable workflow](https://docs.github.com/actions/using-workflows/reusing-workflows).

## Как подключить

1. Скопируй нужный файл из этой папки в `.github/workflows/` своего проекта.
2. Задай в своём репозитории нужные **Variables** и **Secrets**
   (Settings → Secrets and variables → Actions, либо Settings → Environments) —
   полные таблицы см. в документации конкретного workflow, ссылки ниже.
3. Готово. Шаблон вызывает логику отсюда:
   ```yaml
   jobs:
     ci-cd:
       uses: cat-of-summer/git_toolkit/.github/workflows/ci-cd.yml@main
       secrets:
         DEPLOY_KEY: ${{ secrets.DEPLOY_KEY }}
         DOCKER_TOKEN: ${{ secrets.DOCKER_TOKEN }}
         PAT_TOKEN: ${{ secrets.PAT_TOKEN }}
         PACKAGIST_API_TOKEN: ${{ secrets.PACKAGIST_API_TOKEN }}
         SECRETS_JSON: ${{ secrets.SECRETS_JSON }}
   ```

**Секреты перечисляются поимённо.** `secrets: inherit` не используется: если джоба вызванного
workflow объявляет `environment`, унаследованные секреты до неё доходят не всегда. Блок `secrets:`
из шаблона не удаляй и не сокращай, даже если часть секретов в проекте не задана — незаданный
секрет резолвится в пустую строку и просто выключает свой шаг.

**Свой секрет проекта — через `SECRETS_JSON`.** Объявлять каждый новый секрет в двух файлах не
нужно: заведи один секрет `SECRETS_JSON` с JSON-объектом
`{"GOOGLE_PLAY_KEY":"...","SENTRY_DSN":"..."}` — его ключи станут переменными окружения в
`BUILD_COMMAND`, `CI_COMMAND` и `BEFORE_/AFTER_DEPLOY_COMMAND`. **Переменные** (не секреты) так
оборачивать не надо: они доезжают все и сразу, включая заданные в конкретном Environment.

**Проверить, что доехало,** можно по логу шага «Collect vars & secrets»: он печатает имена
пришедших переменных и секретов, без значений.

**Где ищется секрет: сначала Environment ветки, потом секреты репозитория.** Приоритет
обеспечивает сам GitHub: джобы reusable workflow объявляют `environment`, а
[по документации](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows)
значение из Environment перекрывает переданное из шаблона. Строка `${{ secrets.X }}` в самом
шаблоне видит только секреты репозитория и организации — объявить `environment` у джобы с `uses:`
GitHub не позволяет.

**`GITHUB_TOKEN` передавать не надо** — он доступен вызванному workflow всегда, а объявить секрет
с таким именем GitHub запрещает.

**`vars` и `secrets`** внутри логики резолвятся из **твоего** репозитория и его окружений
(environments), а не из git_toolkit. То есть каждый проект настраивает себя сам.

**Закрепление версии.** Шаблоны ссылаются на `@main`. Для стабильности можно закрепиться на
теге или коммите: `...@v1` или `...@<sha>`.

**Permissions.** Права `GITHUB_TOKEN` у reusable workflow не могут превышать права
вызывающего, поэтому нужные `permissions:` уже прописаны в каждом шаблоне — не удаляй их.

---

## Шаблоны

| Шаблон | Триггеры | Назначение | Настройка |
|---|---|---|---|
| `ci-cd.yml` | `push` (ветки и теги `v*`), `pull_request`, `workflow_dispatch` | Сборка и тесты, GitHub Release, публикация в npm / Docker / Packagist, деплой | Переменные в Environment; секреты — в Environment или в репозитории — [документация](../../docs/.github/workflows/ci-cd.yml.md) |
| `grabber.yml` | `workflow_dispatch` | Забирает файлы с сервера в репозиторий, складывает в ветку `sync/...` | `DEPLOY_*` + секрет `DEPLOY_KEY` — [документация](../../docs/.github/workflows/grabber.yml.md) |
| `docgen.yml` | `push` (только ветки), `workflow_dispatch` | Держит структуру `docs/` в соответствии с деревом репозитория | Только `docs/.docignore` — [документация](../../docs/.github/workflows/docgen.yml.md) |
| `minifier.yml` | `push` (только ветки) | Минифицирует `.css` и `.js`, коммитит `*.min.*` | Не настраивается — [документация](../../docs/.github/workflows/minifier.yml.md) |

Полный индекс документации — [`docs/README.md`](../../docs/README.md).
