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
- Apps with several windows get a sector per window
- Live window previews
- Close windows and quit apps without leaving the wheel
- Lives in the menu bar; light and dark

## Install

No releases yet. Needs macOS 14+ and Xcode 16+.

```bash
git clone https://github.com/faustienf/tabwheel.git
cd tabwheel
scripts/setup.sh
```

It asks what to do; the first answer, the default, builds the app, puts it in Applications and starts it. On first launch, the setup window asks for **Accessibility** (required) and **Screen Recording** (optional, for previews).

To update, `git pull` and run `scripts/setup.sh` again: it quits the running copy and replaces it.

## Keys

| | |
|---|---|
| ⌘Tab | Open the wheel |
| Pointer, Tab, ⇧Tab | Select |
| Release ⌘, or click | Switch |
| ⌘W, or × on the selected sector’s outer rail | Close the selected window; the app's last one quits the app |
| ⌘Q | Quit the selected app |
| Esc | Cancel |

## Development

Open `Package.swift` in Xcode and press ⌘R, or run `scripts/setup.sh dev`.

If the app dies without cleaning up and ⌘Tab stops working:

```bash
scripts/setup.sh restore
```

## Something wrong?

Menu bar icon → **Save Log…**, then attach the file to an issue. It has what the app did since launch and its latest crash report: app names and errors, no window titles or keystrokes.

## License

[MIT](LICENSE)
