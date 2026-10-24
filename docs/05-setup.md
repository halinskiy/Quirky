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
