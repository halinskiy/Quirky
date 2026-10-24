# Quirky — инструкции для агентов

macOS menu-bar утилита захвата: OCR, HEX, DOM, SVG, SPX за одним хоткеем ⌘⇧1.
Bundle id `com.threempq.quirky`, Developer ID, нотаризация, Sparkle.

- Читать перед работой: [docs/00-overview.md](docs/00-overview.md), [docs/09-gotchas.md](docs/09-gotchas.md).
- Сборка и релиз: [docs/04-release.md](docs/04-release.md). Работа со второго мака: [docs/05-setup.md](docs/05-setup.md).
- Каждую сессию закрывать записью в [CHANGELOG.md](CHANGELOG.md) и `git push`.
- Коммиты от Kostya Halinskiy, без атрибуции ИИ (никаких Co-Authored-By).
- Если «не работает»: сначала лог `/usr/bin/log show --last 10m --predicate 'subsystem == "com.threempq.quirky"'`, потом гипотезы.
- Слои защиты от залипшего оверлея (docs/09) не удалять: каждый закрывает свой класс отказов.
