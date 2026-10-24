# Архитектура

| Файл | Роль |
|---|---|
| `AppDelegate.swift` | статус-айтем, хоткеи, сессия захвата, `preCaptureScreens()` (CGDisplayCreateImage), watchdog, маршрутизация результата по текущему режиму |
| `OverlayWindow.swift` | `OverlayWindow` (окна на каждый экран, уровень `CGShieldingWindowLevel()`) и `SelectionView` (ввод и HUD всех режимов) |
| `ModePopover.swift` | своя NSPanel с чипами режимов под иконкой, уровень оверлея +1 |
| `SPXAnalyzer.swift` | градиентная и run-карты скриншота для лучей SPX |
| `DOMExtractor.swift`, `SVGExtractor.swift` | JS в браузер через Apple Events, под `#if !MAS_BUILD` |
| `OCREngine.swift` | финальное распознавание выделения |
| `HotkeyManager.swift` | Carbon-хоткеи (⇧Tab регистрируется отдельно от Tab) |

## Отрисовка оверлея (с 24.10.2026)

`SelectionView` слоевой (`wantsUpdateLayer`). Скриншот лежит в `layer.contents` и композитится
GPU, HUD рисуется в прозрачный подслой `hudLayer` через `HUDLayerDelegate` → `drawOverlay(context:)`.
`needsDisplay = true` → `updateLayer()` → перерисовывается только HUD. В ghost-режиме SPX
`contents = nil`, пока скриншот не пришёл, фон чёрный (иначе окно пропускает клики).

Таймер «бегущих муравьёв» (20 Гц) дёргает перерисовку только когда на экране есть пунктир
(`hasMarchingAnts`). HEX читает пиксель из `pixelCache`: скриншот декодируется в RGBA один раз.

Замер на M3 Pro 3024×1964 (стенд из реального `OverlayWindow.swift`): кадр на CPU 0,3–2 мс и до,
и после; WindowServer ~40–50% в обоих случаях. То есть это гигиена, а не лечение заметного лага.
