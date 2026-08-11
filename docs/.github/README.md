<!-- DOCGEN:START -->
# .github

## Папки

- [workflows](workflows/)

<!-- DOCGEN:END -->

| Папка | Что в ней |
|---|---|
| [`workflows/`](workflows/) | Реализации reusable workflow — вся логика живёт здесь. В свой проект **не копируются**, на них ссылаются через `uses:` |
| `.github/workflow-templates/` | Тонкие шаблоны для копирования в `.github/workflows/` своего проекта. Каждый — несколько строк с `uses:` и поимённым списком `secrets:` |

Документации по шаблонам отдельно нет: шаблон и реализация описаны на одной странице —
см. [индекс workflow](workflows/).

Собственных страниц у `workflow-templates/` в `docs/` не будет: каталог исключён в
`docs/.docignore`.
