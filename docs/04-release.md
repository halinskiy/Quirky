# Сборка и релиз

1. Поднять `MARKETING_VERSION` и `CURRENT_PROJECT_VERSION` в `Quirky.xcodeproj`.
2. `Scripts/build.sh` — Release, Developer ID (PDB9JGGX74), hardened runtime, переподпись XPC Sparkle.
3. `Scripts/notarize.sh` — build, zip через ditto, notarytool (профиль `Corder`), staple, spctl.
   Артефакт: `build/Quirky-<version>.zip` (плюс стилизованный DMG).
4. GitHub Release с zip/dmg, новый `<item>` в `appcast.xml`, push в `main`.
   Фид: `https://raw.githubusercontent.com/halinskiy/Quirky/main/appcast.xml`.

Важно: `sparkle:version` в appcast = НОМЕР БИЛДА (сравнивается с `CFBundleVersion`), не маркетинговая версия.

Mac App Store: конфигурация `MAS_BUILD`, `Quirky-MAS.entitlements`, `ExportOptions-MAS.plist`;
DOM и SVG в ней компилируются пустыми (песочница запрещает Apple Events). Отдельного таргета пока нет.
