# Spotty

A small replacement for Spotlight that opens apps, does sums, and keeps timers, alarms and a stopwatch.
No file search, no AI, no web results.

## Install

1. Download `Spotty-<version>.zip` from the [latest release](https://github.com/HusseinElguindi/spotty/releases/latest), unzip it and move **Spotty.app** to **Applications**.
2. Open it. Spotty isn't notarized, so the first launch is blocked: go to System Settings › Privacy & Security and click **Open Anyway** next to Spotty. Once is enough.
3. Turn off Spotlight's ⌘Space (see below) so the shortcut reaches Spotty.

## Releasing

Push a tag such as `v0.1.0`. `.github/workflows/release.yml` runs the tests, builds a universal,
ad-hoc signed `Spotty.app` with that version, and publishes `Spotty-0.1.0.zip` and its `.sha256`
as a GitHub Release with the notes in `.github/release-notes.md`. An icon is picked up from
`Resources/AppIcon.icns` when that file exists.

## Build and run

Runs on macOS 14 or later. Building needs Swift 6.2 or newer (Xcode 26+, or its Command Line Tools).

```sh
scripts/bundle.sh       # universal release build -> build/Spotty.app, ad-hoc signed (version 0.1.0, or pass one)
open build/Spotty.app
```

Spotty has no Dock icon. It lives in the menu bar (a magnifying glass) with Open Spotty, Settings… and Quit.
To keep it, drag `build/Spotty.app` to `/Applications` and turn on "Open at login" in Settings.

For development, `swift run Spotty` runs the debug build without a bundle, and `swift test` runs the core tests.
Debug builds can also render the panel to a PNG without screen-recording permission:

```sh
SPOTTY_SNAPSHOT='saf|/tmp/saf.png;1299*1.13|/tmp/sum.png' SPOTTY_APPEARANCE=light .build/debug/Spotty
```

## Make ⌘Space open Spotty

Spotty registers ⌘Space at launch. Spotlight's shortcut normally holds it, so turn that off once:
System Settings › Keyboard › Keyboard Shortcuts… › Spotlight, then untick "Show Spotlight search".
If the shortcut can't be registered, the menu and Settings say "⌘Space is taken by another app".

## Keys

| Key | Does |
| --- | --- |
| ↩ | Open the selected app, copy the result of a sum, or start or stop a clock |
| ⌘↩ | Reveal the selected app in Finder |
| ↑ ↓ | Move the selection |
| ⇥ | Accept the grey completion |
| esc | Clear the field; press again to close |
| ⌘1–⌘5 | Open a recent app while the field is empty |
| ⌘C | Copy the result of a sum |

## Timers, alarms and the stopwatch

Each one starts with its keyword, so app searches never turn into timers:

| Type | Does |
| --- | --- |
| `timer 5m`, `timer 1h30m`, `timer 4:30`, `tea timer 4 min` | Return starts a timer (a bare number means minutes; any other words become its name) |
| `alarm 7:30`, `alarm 7pm`, `alarm 19:00 standup` | Return sets an alarm for the next time the clock reads that (`7:30` alone picks whichever of 7:30 and 19:30 comes first) |
| `stopwatch` | Return starts the stopwatch, or stops it and shows the time |
| `timer`, `alarm` or `timers` | Lists what's running; Return stops the selected one |

While anything runs, the menu bar shows its icon and the time left (or the stopwatch's time), and
the menu lists each one with Stop. When a timer or alarm goes off, a pill at the top of the screen
chimes every two seconds for up to a minute until you click Stop. Clocks live in memory only, so
quitting Spotty clears them.

## Files

`~/Library/Application Support/Spotty/` holds `usage.json` (what Spotty has learned, with a `.bak`
of the previous good copy) and, if you create it, `aliases.json`: extra names by bundle ID, such as
`{"com.microsoft.VSCode": ["vs", "editor"]}`. Settings › "Reset learned ranking" clears the first.

## Layout

- `Sources/LauncherCore`: the UI-free core (matching, ranking, what it learns, the calculator, the app
  scanner, and parsing timer, alarm and stopwatch commands). Foundation only; `swift test` covers it.
- `Sources/Spotty`: the app. AppKit for the panel, hotkey, FSEvents and launching; SwiftUI for the views.
- `scripts/bundle.sh`: builds `build/Spotty.app`.
- `docs/implementation.md`: how every part works (indexing, re-indexing, matching, ranking, calculator, panel).
- `docs/design.md`: the "B · Quiet" design: sizes, type, colours, keys, motion and copy.
- `docs/plan.md`: the build plan.
