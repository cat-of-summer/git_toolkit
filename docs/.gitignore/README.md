<!-- DOCGEN:START -->
# .gitignore

## Папки

- [Bitrix](Bitrix/)
- [MODX](MODX/)
- [Python](Python/)
- [Wordpress](Wordpress/)

<!-- DOCGEN:END -->

Готовые `.gitignore` под конкретные платформы: не трекают core и runtime, трекают только исходники
проекта.

| Шаблон | Исключает | Трекает |
|---|---|---|
| [Bitrix](Bitrix/.gitignore.md) | `/bitrix/` core, кеши, `/upload/`, логи, бэкапы, секреты | `/local/`, шаблоны, `.settings.php.sample` |
| [Wordpress](Wordpress/.gitignore.md) | `/wp-admin/`, `/wp-includes/`, `/wp-*.php`, плагины, uploads, кеши | `/wp-content/themes/`, `wp-config-sample.php`, `.htaccess`, `robots.txt` |
| [Python](Python/.gitignore.md) | `__pycache__/`, venv, `dist/`, `build/`, кеши тестов и линтеров, `.env` | исходники, `.env.example` |

## Как применить

Скопируй нужный файл в корень проекта:

```bash
cp .gitignore/Bitrix/.gitignore /path/to/project/.gitignore
```

Если репозиторий уже существует и файлы попали в индекс раньше — пересобери индекс, иначе новые
правила не подействуют на уже отслеживаемые файлы:

```bash
git add .gitignore
git commit -m "Update .gitignore"

git rm -r --cached .        # снять с отслеживания (файлы на диске остаются)
git add .                   # добавить заново, уже с учётом правил
git commit -m "Rebuild index according to updated .gitignore"
```
