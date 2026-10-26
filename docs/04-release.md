# Сборка и релиз

1. Поднять `MARKETING_VERSION` и `CURRENT_PROJECT_VERSION` в `Quirky.xcodeproj`.
2. `Scripts/build.sh` — Release, Developer ID (PDB9JGGX74), hardened runtime, переподпись XPC Sparkle.
3. `Scripts/notarize.sh` — build, zip через ditto, notarytool (профиль `Corder`), staple, spctl.
   Артефакт: `build/Quirky-<version>.zip` (плюс стилизованный DMG).
4. GitHub Release с zip/dmg, новый `<item>` в `appcast.xml`, push в `main`.
   Фид: `https://raw.githubusercontent.com/halinskiy/Quirky/main/appcast.xml`.

Важно: `sparkle:version` в appcast = НОМЕР БИЛДА (сравнивается с `CFBundleVersion`), не маркетинговая версия.

## Mac App Store

App Store Connect: «Quirky Screen Capture», app id 6773094144. Бесплатно, 175 стран, категории Productivity + Graphics & Design.
Политика и поддержка: halinskiy.github.io/apps/quirky-privacy.html и quirky-support.html (репо `halinskiy/apps`).

Конфигурация `MAS Release`: `MAS_BUILD`, `Info-MAS.plist`, `Quirky-MAS.entitlements`, профиль «Quirky MAS Distribution».
DOM выключен (песочница запрещает Apple Events). Sparkle вырезается фазой «Strip Sparkle in MAS build»,
а `-Wl,-dead_strip_dylibs` убирает ссылку на него из бинарника. Без этого флага бинарник ссылался на удалённый
Sparkle.framework и магазинная версия падала бы при запуске (проверка: `otool -L ... | grep -i sparkle` должно быть пусто).

```bash
S=/tmp/quirky-mas; KC=~/Library/Keychains/login.keychain-db
xcodebuild -project Quirky.xcodeproj -scheme Quirky -configuration "MAS Release" -archivePath $S/Quirky-MAS.xcarchive archive OTHER_CODE_SIGN_FLAGS="--keychain $KC"
productbuild --component $S/Quirky-MAS.xcarchive/Products/Applications/Quirky.app /Applications \
  --sign "3rd Party Mac Developer Installer: Kostiantyn Halynskyi (PDB9JGGX74)" --keychain $KC $S/Quirky.pkg
xcrun altool --upload-app -t macos -f $S/Quirky.pkg --apiKey 6Q63F35BB6 --apiIssuer <issuer из ~/pult/scripts/ios/asc.py>
```

Подписывать только из `login`: первая связка в списке поиска чужая (Трипілля), без флага codesign падает с
`errSecInternalComponent` или просит пароль, который Костя не знает. Не использовать `-exportArchive`.
Сборку, подписанную для магазина, macOS локально не запускает (exit 137); для проверки песочницы переподписать
копию ad-hoc с `Quirky-MAS.entitlements`.

Метаданные и скриншоты через API: `Scripts/asc/asc.py`, `Scripts/asc/upload_screenshots.py`.
Скриншоты: сцена `Scripts/appstore/scene.html` (Chrome headless 1440×900 @2x), HUD рисует настоящий
`SelectionView.drawHUD` в стенде, кадры `Scripts/appstore/[0-9]-*.png` (2880×1800).
