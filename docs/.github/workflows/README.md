<!-- DOCGEN:START -->
# workflows

## Файлы

- [ci-cd.yml](ci-cd.yml.md)
- [docgen.yml](docgen.yml.md)
- [grabber.yml](grabber.yml.md)
- [minifier.yml](minifier.yml.md)

<!-- DOCGEN:END -->

Реализации reusable workflow. В свой проект копируется не этот файл, а тонкий шаблон из
`.github/workflow-templates/`, который ссылается сюда через `uses:`.

| Workflow | Триггеры | Назначение | Настройка |
|---|---|---|---|
| [ci-cd.yml](ci-cd.yml.md) | `push` (ветки и теги `v*`), `pull_request`, `workflow_dispatch` | Сборка и тесты, GitHub Release, публикация в npm / Docker / Packagist, деплой на сервер | Много переменных в Environment; секреты — в Environment или в репозитории |
| [grabber.yml](grabber.yml.md) | `workflow_dispatch` | Забирает файлы **в репозиторий** — с сервера или из другого git-репозитория, складывает в ветку `sync/...` | Для сервера — `DEPLOY_*` и секрет `DEPLOY_KEY`; для git-источника — входы `source_*` и секреты `PAT_*` |
| [docgen.yml](docgen.yml.md) | `push`, `workflow_dispatch` | Держит структуру `docs/` в соответствии с деревом репозитория | Только `docs/.docignore` |
| [minifier.yml](minifier.yml.md) | `push` | Минифицирует `.css` и `.js`, коммитит `*.min.*` | Не настраивается |

Workflow независимы друг от друга — подключать можно любой набор. Автоматические коммиты
(`docgen`, `minifier`, `grabber`) выполняются от имени `github-actions[bot]`; у `docgen` и
`minifier` сообщение содержит `[skip ci]`, чтобы запуски не зацикливались.
