<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="⌘Tab Wheel icon">
</p>

<h1 align="center">⌘Tab Wheel</h1>

<p align="center">A radial app switcher for macOS: hold ⌘, press Tab, point at an app, let go.</p>

<p align="center">
  <img src="docs/screenshot.jpg" alt="The wheel open over a macOS desktop: nine apps around a ring, Terminal selected, a preview of its window in the middle">
</p>

## Features

- Pick an app by direction; the pointer can be anywhere on screen
- Apps keep their slots, in launch order
- A quick ⌘Tab jumps back to the previous app
- Apps with several windows get a sector per window, or a fan of thumbnails past the rim
- Live window previews
- Lives in the menu bar; light and dark

## Install

No releases yet. Needs macOS 14+ and Xcode 16+.

```bash
git clone https://github.com/faustienf/tabwheel.git
cd tabwheel
scripts/build-app.sh
open build/CmdTabWheel.app
```

On first launch, the setup window asks for **Accessibility** (required) and **Screen Recording** (optional, for previews).

## Keys

| | |
|---|---|
| ⌘Tab | Open the wheel |
| Pointer, Tab, ⇧Tab | Select |
| Release ⌘, or click | Switch |
| Esc | Cancel |

## Development

Open `Package.swift` in Xcode and press ⌘R, or run `scripts/run.sh`.

If the app dies without cleaning up and ⌘Tab stops working:

```bash
build/CmdTabWheel.app/Contents/MacOS/CmdTabWheel --restore-native-switcher
```

## License

[MIT](LICENSE)
