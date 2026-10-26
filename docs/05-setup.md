# Окружение и второй мак

- Клон: `git clone https://github.com/halinskiy/Quirky ~/quirky`. Перед работой `git pull`.
- Xcode с SDK macOS 26+, deployment target 13.0 (поэтому `CGDisplayCreateImage` ещё компилируется).
- Подпись: сертификат Developer ID в связке `login`, notarytool-профиль `Corder`
  (`xcrun notarytool store-credentials Corder ...` на новом маке).
- Права в системе: только Screen Recording для `/Applications/Quirky.app` (хоткеи Carbon, Accessibility не нужен);
  после переустановки иногда надо снять и поставить галочку заново.
- Отладочная сборка без подписи:
  `xcodebuild -project Quirky.xcodeproj -scheme Quirky -configuration Debug build CODE_SIGNING_ALLOWED=NO`.
- Лог захвата: `/usr/bin/log show --last 10m --predicate 'subsystem == "com.threempq.quirky"'` (в zsh голый `log` это встроенная команда).
- Синтетические нажатия из терминала (CGEvent) до Quirky не доходят, а computer-use не видит
  menu-bar приложение. Для замеров собирать стенд из `OverlayWindow.swift` + `SPXAnalyzer.swift`
  + `DOMExtractor.swift` и своего `main.swift`.

## Диагностика DOM (direct-сборки)

`Scripts/build.sh` читает `APPS_TELEMETRY_INGEST_KEY` только из окружения и добавляет конфигурацию
в собранный `.app` перед финальной подписью. Ключ и dashboard token в исходники не записывать.
Без ingest key остаётся локальный лог (`category == "browser"`), без сетевой отправки.

```bash
source ~/.config/claude-secrets/secrets.env
export APPS_TELEMETRY_INGEST_KEY
Scripts/build.sh
```

Отправляются только исходы операций DOM: bundle id браузера, код AppleScript, длительность,
количество результатов и служебные идентификаторы. Содержимое страницы, селекторы, URL,
названия окон и буфер не отправляются. Доставка best effort, без дисковой очереди и повторов.
В `MAS Release` код DOM и диагностики исключён, а ключ и endpoint в `.app` не добавляются.
Nothing и другие Chromium требуют вручную включить `View > Developer > Allow JavaScript from Apple Events`;
Quirky настройки браузера не меняет.

Регрессионный стенд без запуска браузеров и без сетевой отправки: `bash Tests/browser-automation.sh`.
