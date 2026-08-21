<p align="center">
  <img src="Quirky/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" height="128" alt="Quirky icon">
</p>

<h1 align="center">Quirky</h1>

<p align="center">
  A lightweight macOS menu bar capture suite — five precise tools behind one global hotkey.<br>
  Press <kbd>⌘⇧1</kbd> to capture; switch tools on the fly from the menu-bar picker.<br>
  Results land in your clipboard instantly.
</p>

---

## Modes

**OCR** — freezes the screen, highlights every recognized word. Select a region or click a word; text is in your clipboard before the overlay closes. Adjacent words on the same line merge into one clean selection.

**HEX** — eyedropper. Hover any pixel; the exact hex color follows your cursor. Click to copy.

**DOM** — element inspector for any open page in Safari/Chrome/Arc/Brave/Edge/Comet/Vivaldi/Opera. Click an element to copy its label, role, or tag.

**SVG** — extracts real SVG source from the same browsers. Click an icon or drag over several; clean vector markup lands in your clipboard, ready to paste into Figma. No browser extensions.

**SPX** — PixelSnap-style pixel measurement. Magnetic edge detection, free-drag rect → snap-on-release, ruler crosshair, resizable handles on every side, hover-reveal close button, ghost mode (⌘⇧1 toggle) lets you keep markings translucent over the live screen.

Rulers stop at whatever they meet first: a detected edge, or a measurement you already placed. Drop a guide with <kbd>H</kbd>/<kbd>V</kbd> and the next ruler measures right up to it. Hold <kbd>Shift</kbd> to ignore every obstacle and run a guide the full width or height of the screen. <kbd>T</kbd> cycles three snap levels — **Window** (structural borders), **Element** (cards, buttons, inputs), **Detail** (icons, glyphs, hairlines). <kbd>⌫</kbd> undoes the last mark, <kbd>esc</kbd> exits.

## Mode picker

Enable the modes you use in the settings menu (right-click the menu-bar icon). Press <kbd>⌘⇧1</kbd> — capture opens in the mode you used last, and a picker drops down from the menu-bar icon with a chip per enabled mode. Click a chip to switch tools without leaving capture, or click the icon any time to open the picker and start a session straight from it. The picker closes as soon as you start working. <kbd>Tab</kbd> cycles modes forward during capture, <kbd>⇧Tab</kbd> backward.

## Installation

1. Download the latest **Quirky.dmg** from [Releases](../../releases)
2. Open the disk image and drag **Quirky.app** into **Applications**
3. Launch and grant the required permissions:
   - **Screen Recording** — for capture across every mode
   - **Accessibility** — for the global hotkey
   - **Automation** — for SVG and DOM extraction from browsers (prompted on first use)

Quirky is signed with a Developer ID Application certificate and notarized by Apple — no quarantine bypass or `xattr` removal needed. A `.zip` of the bundle is also published alongside the DMG for Sparkle auto-updates.

## Building from source

```bash
git clone https://github.com/halinskiy/Quirky.git
cd Quirky
xcodebuild -scheme Quirky -configuration Release build
```

The built app will be in `~/Library/Developer/Xcode/DerivedData/Quirky-*/Build/Products/Release/`.

To produce a signed + notarized release `.zip`, see `Scripts/notarize.sh` (requires Developer ID Application identity in your login keychain and a `Quirky` notarytool keychain profile — see `Scripts/notarize.sh` header for setup).

## Requirements

- macOS 13.0+ (running)
- Xcode 15+ (building from source)
- Apple Developer Program account (notarizing your own builds; not required for use)

## Tech stack

Swift, AppKit, Vision framework, CoreGraphics, ScreenCaptureKit, Sparkle for auto-updates. No SwiftUI, no Storyboards.

## License

MIT
