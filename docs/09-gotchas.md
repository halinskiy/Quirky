# Грабли

## Залипший оверлей (чинилось 17.08.2026)
Экран статичным скриншотом, выйти нельзя. Защита слоями, ничего не удалять:
1. `OverlayWindow.isGhost` + `applyInteractivity()` — единственный писатель `ignoresMouseEvents`; `forceInteractive()` из каждого `switchTo*Mode`.
2. Esc — Carbon-хоткей на всю сессию; `forceExitCapture()` — безусловный выход.
3. `didResignActiveNotification` → `yieldOverlay()`: SPX уходит в ghost, остальные закрываются.
4. Watchdog 1 Гц: окна без `isCapturing` закрыть; click-through вне ghost починить; 4 с без событий при активной мыши → yield; 120 с тишины → закрыть.
5. Тройной ⌘⇧1 = аварийный выход только при `overlaySeemsWedged`.
6. `showOverlay` сносит старые окна перед созданием новых.
`lastOverlayActivity` трогать при каждом хоткее и выходе из ghost.

## Выделение терялось при смене режима (21.08.2026)
`OverlayWindow.onRectSelected` ставится один раз в AppDelegate и маршрутизируется по ТЕКУЩЕМУ режиму. Не возвращать колбэк параметром show-методов.

## Поповер прыгал по меню-бару
Статус-айтем только иконкой: подпись меняла ширину, AppKit применяет её на такт позже. Подсветка иконки `button.highlight(true)` строго в `DispatchQueue.main.async`.

## SPX
Порог толерантности выше ~12 проскакивает сквозь границы тёмных окон. Смена уровня пересобирает run-карты (~54 мс на 2560×1600).

## Отрисовка
Не возвращать рисование скриншота в `draw(_:)`: фон живёт в `layer.contents`, HUD в `hudLayer` (см. 01-architecture).

## macOS 26 Core Text
Строки HUD строятся через CTLine из именованных CTFont, не через `monospacedSystemFont`: ленивые дескрипторы падали в `CTLineCreate`.

## OCR молча не копирует (24.10.2026)
Две причины подряд. Первый клик по оверлею уходил на активацию окна (Quirky не становится активным по хоткею на новых macOS), поэтому `SelectionView.acceptsFirstMouse` = true, не убирать. Модель Vision `.accurate` macOS выгружает в простое, и холодная загрузка под нагрузкой занимает 30–70 с; `OCREngine.keepWarm()` держит её загруженной. `.fast` не читает кириллицу («HoBblk1» вместо «Новый»), поэтому быстрый режим только запасной.
Диагностика: `/usr/bin/log show --last 10m --predicate 'subsystem == "com.threempq.quirky"'`.
