# Quirky: DOM в браузере Nothing + разбор телеметрии

Репозиторий `~/quirky` (halinskiy/quirky). Сначала прочитай `AGENTS.md`, `docs/01-architecture.md`, `docs/09-gotchas.md`.

## 1. DOM не работает в Nothing
Nothing — личный браузер Кости на Chromium/Helium, bundle id `com.3mpq.nothing`, имя приложения `Nothing`, словарь AppleScript как у Chrome (`execute javascript` у tab).
Причины:
- `Quirky/DOMExtractor.swift` `detectBrowser`: id нет в списке `chromiumIDs` и он не содержит "chrome", поэтому возвращается nil. Добавь `com.3mpq.nothing`. Проверь то же в `SVGExtractor.swift` и везде, где есть список браузеров (grep по `ai.perplexity.comet`).
- В Nothing выключено «View > Developer > Allow JavaScript from Apple Events»: osascript отдаёт ошибку -?, текст «Executing JavaScript through AppleScript is turned off». Сейчас Quirky, вероятно, молча ничего не копирует. Сделай так, чтобы при этой ошибке (любой Chromium) показывался понятный тост: «Включите в браузере View > Developer > Allow JavaScript from Apple Events», а не тишина. Найди, как тосты показываются для других ошибок, и используй тот же путь.
- Проверь, что прочие ошибки AppleScript (нет прав Automation, -1743) тоже дают понятный тост, а не тишину.

## 2. Телеметрия
Бэкенд: `https://apps-telemetry.empqwork.workers.dev/raw.json?t=$APPS_TELEMETRY_DASH_TOKEN&app=quirky&limit=...` (фильтры app, type, session_id, install_id, since, limit). Токен: `source ~/.config/claude-secrets/secrets.env`. Таймлайн сессии: `/session/<id>?t=...`.
Выгрузи события Quirky за последние 30 дней (если app называется иначе, посмотри без фильтра). Найди краши, ошибки, неудачные OCR/DOM/SVG/HEX/SPX, долгие длительности, повторяющиеся паттерны, bundle id браузеров, где DOM падал. Для каждой проблемы найди причину в коде и почини, если причина ясна и правка безопасна. Неясное запиши в отчёт с данными, не гадай.
Если телеметрия не пишет то, что нужно для диагностики DOM (bundle id браузера, код ошибки AppleScript, длительность), добавь эти поля. Без контента: текст, заголовки, URL и буфер не слать.

## 3. Сборка и проверка
- Dev-сборка как в `docs/05-setup.md` / `Scripts/build.sh` (подпись из login keychain, связку Трипілля не трогать). Должна собираться без ошибок и для `Release`, и для `MAS Release` (в MAS нет DOM/SVG, проверь, что `#if MAS_BUILD` не сломан).
- Нельзя: переустанавливать Quirky в /Applications, перезапускать или закрывать Nothing (им пользуются другие агенты и Костя), менять настройки Nothing, коммитить и пушить. Это сделает Claude.
- Проверить AppleScript можно так: `osascript -e 'tell application "Nothing" to tell active tab of front window to execute javascript "1+1"'` (сейчас ожидаемо вернёт ошибку «turned off»).

## Отчёт
Положи в `docs/codex-tasks/2026-10-26-dom-nothing-telemetry-report.md`: что нашёл в телеметрии (цифры), что исправил (файлы), что не исправил и почему, результат сборок.
