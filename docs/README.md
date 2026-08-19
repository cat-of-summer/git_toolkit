<!-- DOCGEN:START -->
# git_toolkit

## Папки

- [.github](.github/)
- [.gitignore](.gitignore/)

<!-- DOCGEN:END -->

Набор готовых **reusable workflow** для GitHub Actions и шаблонов `.gitignore`. Подключается в
чужой проект копированием тонкого шаблона — логика остаётся здесь и обновляется централизованно.

## Workflow

| Workflow | Триггеры | Назначение |
|---|---|---|
| [ci-cd](.github/workflows/ci-cd.yml.md) | `push` (ветки и теги `v*`), `pull_request`, `workflow_dispatch` | Сборка и тесты на нескольких ОС, GitHub Release, публикация в npm / Docker / Packagist, деплой на сервер |
| [grabber](.github/workflows/grabber.yml.md) | `workflow_dispatch` | Забирает файлы с сервера в репозиторий и складывает их в ветку `sync/...` |
| [docgen](.github/workflows/docgen.yml.md) | `push`, `workflow_dispatch` | Держит структуру `docs/` в соответствии с деревом репозитория |
| [minifier](.github/workflows/minifier.yml.md) | `push` | Минифицирует `.css` и `.js`, коммитит `*.min.*` рядом с исходниками |

## Шаблоны подключения

В `.github/workflow-templates/` лежат тонкие шаблоны — по несколько строк каждый:

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

- Секреты перечисляются поимённо; `secrets: inherit` не используется — до джоб, объявляющих
  `environment`, унаследованные секреты доходят не всегда. Блок `secrets:` не сокращай: незаданный
  секрет резолвится в пустую строку и просто выключает свой шаг.
- Свой секрет проекта не требует правки YAML: заведи `SECRETS_JSON` с JSON-объектом
  `{"GOOGLE_PLAY_KEY":"..."}` — его ключи станут переменными окружения в пользовательских командах.
  Переменные (не секреты) так оборачивать не надо, они доезжают все и сразу.
- Секрет ищется **сначала в Environment ветки, потом в секретах репозитория** — значение из
  Environment перекрывает переданное из шаблона. Сама строка `${{ secrets.X }}` в шаблоне видит
  только секреты репозитория и организации.
- `GITHUB_TOKEN` передавать не надо — он доступен вызванному workflow всегда.
- В пользовательских командах (`BUILD_COMMAND`, `CI_COMMAND`, `BEFORE_/AFTER_DEPLOY_COMMAND`)
  доступны **все переменные и секреты проекта** по своим именам, плюс два токена: `$GH_TOKEN` —
  встроенный `GITHUB_TOKEN`, права только на текущий репозиторий; `$PAT_TOKEN` — секрет
  `PAT_TOKEN`, нужен для приватных зависимостей из **чужих** репозиториев. В сборку образа оба
  приходят build-arg'ами.
- SSH-ключи GitHub на сервере не обязательны: если рабочего ключа нет, git на время деплоя ходит
  по HTTPS под токеном раннера. Подробности — в
  [документации ci-cd](.github/workflows/ci-cd.yml.md).
- `vars` и `secrets` резолвятся из **твоего** репозитория и его Environments, а не из git_toolkit:
  каждый проект настраивает себя сам.
- Ссылка `@main` даёт свежую версию; для стабильности можно закрепиться на теге или коммите
  (`...@v1`, `...@<sha>`).
- Блок `permissions:` в шаблоне не удаляй: права `GITHUB_TOKEN` у reusable workflow не могут
  превышать права вызывающего.

## Быстрый старт (ci-cd)

1. Скопируй `.github/workflow-templates/ci-cd.yml` в `.github/workflows/` своего проекта.
2. Settings → Environments → New environment, имя = имя ветки (например `main`; слеши в имени ветки
   заменяются на дефис: `release/1.x` → `release-1.x`).
3. В этом Environment задай Variables:
   ```
   ACTION_TRIGGER=push
   CI_COMMAND=npm test
   ```
4. Запушь в `main` — прогонятся тесты.

Дальше — по [полной документации ci-cd](.github/workflows/ci-cd.yml.md): сборка на нескольких ОС,
релизы по тегам, публикация в реестры, деплой. Незаданная переменная просто выключает свой шаг,
а джоба становится серой, а не красной.

## Шаблоны .gitignore

Готовые `.gitignore` под Bitrix, WordPress и Python — см. [`.gitignore/`](.gitignore/).

## Служебное

- [`docs/.docignore`](.docignore) — что docgen **не** документирует; единственная настройка docgen.
- Автоматические коммиты (`docgen`, `minifier`, `grabber`) выполняются от имени
  `github-actions[bot]`.
- Новый workflow или изменение переменных удобно обкатывать на отдельной ветке с собственным
  Environment, а не сразу в `main`.
