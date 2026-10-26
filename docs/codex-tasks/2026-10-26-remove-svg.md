# Quirky: вырезать режим SVG навсегда

Репозиторий `~/quirky`. Прочитай `AGENTS.md`. Костя решил убрать режим SVG полностью. Режимы остаются: OCR, HEX, DOM, SPX.

Сделать:
- Удалить `case svg` из `CaptureMode` и всё, что с ним связано: `Quirky/SVGExtractor.swift` (файл и все ссылки в `Quirky.xcodeproj/project.pbxproj`), SVG-ветки в `AppDelegate.swift` (switch, `performSVGExtraction`, поповер, меню, настройки включённых режимов) и в `OverlayWindow.swift` (`switchToSVGMode`, `setSVGBoxes`, отрисовка боксов, подсказки HUD). Строки про SVG в `Info.plist` (например, usage description), если они больше не нужны.
- Сохранённые настройки: `UserDefaults` `lastCaptureMode` и список включённых режимов (`EnabledModesStore`) у Кости могут содержать `"svg"`. После обновления это не должно ничего ломать: неизвестное значение молча отбрасывается, режим по умолчанию OCR, переключение Tab/Shift+Tab ходит по оставшимся включённым режимам.
- `.svg`-файлы иконок в `Scripts/` НЕ трогать, это ассеты, не режим.
- Документация: убрать режим SVG из `README.md`, `AGENTS.md`, `docs/00-overview.md`, `docs/01-architecture.md`, `docs/04-release.md`, `docs/05-setup.md`, `docs/02-usage.md` (если есть); строка в `CHANGELOG.md` в Unreleased: «Режим SVG удалён».
- Больше НИЧЕГО не менять: ни логику OCR, DOM, HEX, SPX, ни фокус, ни хоткеи, ни рефакторинг. Минимальный дифф.

Проверка: `Scripts/build.sh` (Release) и `BUILD_CONFIG='MAS Release' QUIRKY_SIGN_IDENTITY='Apple Distribution: Kostiantyn Halynskyi (PDB9JGGX74)' Scripts/build.sh` без ошибок и предупреждений о SVG; `grep -rni svg Quirky/` пусто (кроме ничего). В конце пересобери Release ещё раз последним, чтобы в `build/Quirky.app` лежал Release.
Нельзя: устанавливать в /Applications, запускать Quirky, коммитить, пушить. Отчёт коротко (что удалено, результат сборок) в `docs/codex-tasks/2026-10-26-remove-svg-report.md`.
