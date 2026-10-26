# Удаление режима SVG — 26.10.2026

Удалены `CaptureMode.svg`, `SVGExtractor.swift` и ссылки Xcode, ветки извлечения и переключения, состояние и боксы SVG в оверлее. Обновлены строки разрешений, README, AGENTS и указанные документы; в Unreleased добавлено «Режим SVG удалён». В `docs/02-usage.md` упоминаний не было.

Хранилища настроек уже отбрасывают неизвестные значения; менять их не потребовалось. Изолированный Swift-стенд для Release и MAS проверил старое `"svg"`, смешанные/пустые списки, OCR по умолчанию, сохранение допустимого режима и Tab/Shift+Tab по оставшимся включённым режимам. Настройки пользователя не изменялись.

Сборки (все exit 0; проверка подписи успешна):
- `Scripts/build.sh` — Release.
- `BUILD_CONFIG='MAS Release' QUIRKY_SIGN_IDENTITY='Apple Distribution: Kostiantyn Halynskyi (PDB9JGGX74)' Scripts/build.sh` — MAS Release.
- `Scripts/build.sh` — финальный Release; в `build/Quirky.app` проверены Developer ID и Sparkle.

Ошибок и предупреждений о SVG нет. Во всех трёх сборках только предупреждение Xcode о нескольких подходящих destinations. Логи: `/tmp/quirky-remove-svg-{release,mas-release,release-final}.log`.

`grep -rni svg Quirky/` пусто (exit 1); ссылки в проекте и указанных актуальных документах отсутствуют; `git diff --check` проходит. Ассеты и скрипты в `Scripts/` не менялись. Quirky не запускался и не устанавливался; GUI не проверялся. Commit/push не выполнялись.
