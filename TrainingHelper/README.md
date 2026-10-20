# TrainingHelper

A small macOS menu-bar app for **online training and screen sharing** (Teams, Zoom, Meet…).
It adds the things a trainer keeps wishing for while sharing a screen: a visible cursor, click
feedback, drawing, a spotlight, a magnifier for tiny toolbar icons, text annotations and a break
timer that is, fittingly for a CFD course, a live fluid simulation.

Everything is drawn as transparent overlay windows, so it shows up for the audience when you share
your **entire screen**. No window of its own gets in your way, and nothing is installed system-wide.

## Features

| Feature | How |
|---|---|
| **Cursor halo** | always on, a coloured ring that is easy to follow on a shared screen |
| **Click ripples** | left click = red ripple, right click = blue ripple; switch on/off in the menu |
| **Quick drawing** | hold `Fn`+`Shift` and drag; the drawing fades out shortly after you release the keys |
| **Quick rectangle** | hold `Fn`+`Shift`+`Option` and drag |
| **Spotlight** | `⌃⌥S` dims the screen except for a soft circle around the cursor; size in the menu |
| **Magnifier** | hold `Fn`+`Control`; scroll = zoom (1.5×–10×), `Option`+scroll = size of the lens |
| **Annotate** | `⌃⌥A` draw, box and type on the live screen until you press `Esc` |
| **Freeze + annotate** | `⌃⌥F` freezes the screen as a still image first, then same as above |
| **Break timer** | menu → *Break timer*; digits are obstacles in a 2D incompressible flow |

### Annotate mode keys

| Key | Action |
|---|---|
| `P` / `R` / `T` | pen / rectangle / text |
| `1` … `5` | colour: red, yellow, green, blue, white |
| `↑` / `↓` | bigger / smaller pen and text |
| `⌫` or `⌘Z` | undo last item |
| `X` | clear everything |
| `Esc` | leave annotate mode (and return to the app you were in) |

Text tool: click where the text should go and type. `Return` finishes the text, `Shift+Return`
inserts a new line. Accents and dead keys (ť, ď, ň, é…) work.
A blue frame around the screen means *annotate*, an orange frame means *frozen*.

### Break timer

Pick a duration from the ✎ menu (1, 5, 10, 15, 20 minutes or custom). A colourful dye stream flows
around the countdown digits and sheds vortices behind them. In the last minute the dye turns
orange-red; at zero the colours start cycling and the flow speeds up.
Drag the window to move it, **double-click** for full screen, `Esc` closes it.

## Requirements

- macOS 14 (Sonoma) or newer
- Xcode Command Line Tools: `xcode-select --install` (no full Xcode needed)

## Build and run

```bash
git clone <this repository>
cd TrainingHelper
bash build.sh
open TrainingHelper.app
```

The app lives in the menu bar (✎), has no Dock icon and quits from that menu.
To keep it, copy `TrainingHelper.app` to `/Applications`; add it under *System Settings → General →
Login Items* to start it automatically.

## Permissions

macOS asks for these on first use:

| Permission | Needed for |
|---|---|
| **Accessibility** and/or **Input Monitoring** | seeing the `Fn`/`Shift`/`Control` keys, mouse clicks and movement while another app is active |
| **Screen & System Audio Recording** | the magnifier and *Freeze screen* only |

Grant them under *System Settings → Privacy & Security*, then **quit and start the app again**.

### Why does macOS keep asking after I rebuild?

macOS ties these permissions to the app's code signature. `build.sh` signs with a *certificate* when
it finds one called `TrainingHelper Dev` in your keychain and falls back to an *ad-hoc* signature
otherwise. An ad-hoc signature changes with every build, so macOS forgets the permissions after each
rebuild. Restarting the same build keeps them.

To make them stick across rebuilds, create a code-signing certificate once (see [SETUP.txt](SETUP.txt)),
or sign with your own identity:

```bash
SIGN_ID="Apple Development: Your Name (XXXXXXXXXX)" bash build.sh
```

If you only build once and copy the app to `/Applications`, you do not need any of this.

## Sharing in Teams / Zoom

- Share the **entire screen** (not a single window), otherwise the overlays are not part of what the
  audience sees.
- Several displays are supported; the overlays follow display changes (plug/unplug, sleep/wake).
- The cursor halo is drawn by the app, so it is visible even when the meeting software does not show
  your real cursor.

## Tips and troubleshooting

- **Fn key opens the emoji picker or dictation:** *System Settings → Keyboard → "Press 🌐 key to"* →
  *Do Nothing*.
- **A shortcut does nothing:** another app may own that combination. The app shows an alert at start
  if a hotkey cannot be registered; the menu entries always work.
- **Magnifier or freeze shows nothing:** check *Screen & System Audio Recording*, then restart the app.
- **Scrolling zooms instead of scrolling the page:** that is intended while `Fn`+`Control` is held.

## Configuration

Colours, sizes, timings and the key combinations are plain constants:

- `State.swift` → `enum Config`: pen/halo/ripple colours, fade times, lens size, zoom range, palette
- `App.swift` → `registerHotKeys()`: the `⌃⌥S`, `⌃⌥A`, `⌃⌥F` hotkeys
- `FluidTimer.swift` → `class Fluid`: flow speed, vorticity, dye colours and stripes

Spotlight size, click ripples on/off are saved automatically (`UserDefaults`).

## Project layout

```
main.swift        app entry point
App.swift         menu bar item, menu, hotkey registration, overlay windows per display
State.swift       settings, all input handling, drawing / annotate / magnifier logic
Overlay.swift     transparent overlay window and its drawing (halo, ripples, lens, HUD…)
Capture.swift     ScreenCaptureKit helpers (freeze snapshot, live capture for the lens)
HotKeys.swift     system-wide hotkeys (Carbon), independent of keyboard layout
FluidTimer.swift  break timer: stable-fluids solver, text-as-obstacle mask, timer window
build.sh          builds and signs TrainingHelper.app
SETUP.txt         one-time signing certificate setup
```

## How it works (short)

- One borderless, click-through window per display sits above everything; it only captures the mouse
  while you draw, magnify or annotate.
- Global key and mouse events come from `NSEvent` monitors; the three shortcuts are Carbon hotkeys.
- The magnifier streams the display with ScreenCaptureKit (only while the keys are held) and crops
  the region around the cursor; the app's own windows are excluded from the capture.
- The timer is a 2D Stam-style "stable fluids" solver with vorticity confinement on a coarse grid;
  the digits are rasterised into a mask and act as solid obstacles.

## Status

Small personal tool, built for OpenFOAM trainings. Issues and pull requests are welcome.

## License

Copyright (C) 2026 Matej Forman.
TrainingHelper is free software, released under the
[GNU General Public License v3.0 or later](LICENSE) (`GPL-3.0-or-later`).
You may use, study, share and modify it; if you distribute a modified version, it must stay under the
same license with its source available.
