# Design: B · Quiet

Hussein picked this direction on 2026-10-26. The live prototype and the full spec are on the
[Launcher design directions](https://claude.ai/artifact/3roF8v8c79ZPXBPbg9wJ19) canvas, on its "Quiet" page.
This file copies what the Swift code needs. Sizes are in points.

## Behaviour

- Opens on ⌘Space once Spotlight's own shortcut is turned off, on the screen that has the pointer,
  centred and a third of the way down unless you have moved it.
- Closes when an app opens, on a second Esc, or when you click anywhere else.
- Drag it by anything but the field's text to move it. While you drag, two guides show: the
  screen's centre line and the line the standard top edge sits on. Within 12 pt of either, the
  panel sticks to it, so the standard spot is easy to find again. The guides are dashed in ink-4,
  and solid indigo while the panel sticks. Every later open, and relaunch, uses the new spot,
  scaled to the screen it opens on. The panel never moves so low that six results would run off the screen.
- Closing with ⌘Space keeps what you typed. The next open shows it again, all selected, so typing
  replaces it. Every other way of closing clears the field.
- An empty field lists your five most recent apps, with ⌘1 to ⌘5 beside them.
- A search shows at most six rows. Matched letters are drawn in ink-1 at weight 600.
- Picking anything but the top result teaches that query. The why line says so before you press
  Return. Nothing shows after an app opens (Hussein, 2026-10-27): the app itself is the confirmation.
- Anything with a digit and an operator is a sum. A sum replaces the app list with the math tray.
  While it is unfinished, the tray shows the value so far in ink-3.
- `timer`, `alarm` and `stopwatch` (as whole words) open the clock tray in place of the list. It is
  the math tray's twin: a caption in ink-3, a 42 pt figure (`10:00`, `7:30 AM`, `0:02.3`) with
  monospaced digits, and one filled button: Start, Set (alarms) or Stop (a running stopwatch).
  The keyword alone lists what's running as rows (icon, name, live figure in ink-4, a "Stop ↩"
  keycap on the selected row) with a why line saying how to add another.
- While a clock runs, the menu bar swaps the magnifying glass for the clock's icon and its figure.
- A timer or alarm going off shows the ring pill: plate, full radius, 36 tall, at the top of the
  screen, an indigo bell, the text in ink-1, and a filled Stop button. It stays until Stop.

## Anatomy

| # | Part | Spec |
| --- | --- | --- |
| 1 | Panel | 560 wide, radius 16, padding 4 at the top and 8 elsewhere. Fill `panel`, shadow-panel. Opaque, not glass. |
| 2 | Field | 50 tall, 17 / 500, −0.2 tracking, ink-1. Magnifier 16 in ink-3. The completion follows in ink-4, same face; Tab accepts it. Placeholder: "Open an app or calculate". |
| 3 | Section label | 24 tall, 11 / 500 in ink-3, the count in ink-2 at 400. Reads Recent, Apps or Math. |
| 4 | Selected row | fill-selected with a 1 pt inset ring and a ↩ keycap at the end. Matched letters in ink-1 at 600. |
| 5 | Row | 34 tall, 1 apart, radius 10. Icon 22 at radius 5, then 10 to the name: 13 / 17 in ink-2. Six rows at most. |
| 6 | Why line | 11 / 14 in ink-4 after an indigo sparkle. Says why the top result is first, or what Return is about to teach. |
| 7 | Math tray | wash with a 0.5 pt ring, radius 12. Expression 12 / 18 in ink-3. Result 42 / 600, −1.47 tracking, separators (`,` and `.`) in ink-4. |
| 8 | Copy | The one filled button in a view: accent with on-accent text, full radius, 30 tall. Label "Copy" plus a ↩ glyph. |
| 9 | Capsule | plate with shadow-popover, full radius, 36 tall, in place of the closed panel. Confirms a copied sum, then fades. Never shown after opening an app. |

## Type

| Role | Sample | Size / line height · weight · tracking |
| --- | --- | --- |
| Result | 1,467.87 | 42 / 46 · 600 · −1.47 |
| Field | Safari | 17 / 22 · 500 · −0.2 |
| Row | Visual Studio Code | 13 / 17 · 400, matches 600 |
| Expression | 1,299 × 1.13 | 12 / 18 · 400 |
| Meta | ⌘1 ⌘2 ⌘3 | 11.5 / 16 · 400 |
| Label | Recent | 11 / 13 · 500 |
| Why line | Safari is first because you picked it for “sa” 9 times. | 11 / 14 · 400 |
| Keycap | ↩ | 10.5 / 18 · 500 |

System font (SF Pro) throughout.

## Colour tokens

Colours follow Hussein's Rex terminal theme. Rex is dark only, so light is derived from the same GitHub Light family.

| Token | Dark | Light | Used for |
| --- | --- | --- | --- |
| panel | #1C1C1C | #F6F8FA | The panel |
| ink-1 | #E6EDF3 | #1F2328 | Typed text, selected row, result |
| ink-2 | #C9D1D9 | #31363C | Row names, counts |
| ink-3 | #B1BAC4 | #424A53 | Section labels, expression, magnifier |
| ink-4 | #8B949E | #59636E | Completion, why line, ⌘ numbers, separators |
| fill-selected | white 10% | black 6% | Selected row, with a 1 pt ring (white 16% / black 12%) |
| fill-quiet | white 8% | black 6% | Keycaps |
| wash | white 5% | black 4.5% | Math tray (ring white 7% / black 7%) |
| plate | #2A2A2A | #FFFFFF | Capsule |
| indigo | #58A6FF | #0969DA | Sparkle: the app noticed something |
| accent | #E6EDF3 | #1F2328 | Copy button; its text is on-accent (#0D1117 dark, #FFFFFF light) |

Panel shadow: dark has a 0.5 pt inner ring of white 10% and a soft drop shadow (0 24 48, black 55%);
light has a 0.5 pt inner ring of black 10% and a drop shadow (0 20 50, black 35%).
Follow the system appearance.

## Keys

| Key | Does |
| --- | --- |
| ↩ | Open the selected app, copy the result of a sum, or start or stop a clock |
| ↑ ↓ | Move the selection |
| ⇥ | Accept the grey completion |
| esc | Clear the field; press again to close |
| ⌘1–⌘5 | Open a recent app while the field is empty |
| ⌘C | Copy the result of a sum |

## Motion

| What | How | Time | Curve |
| --- | --- | --- | --- |
| Open | Appears at once at its final size, no fade or drop (Hussein, 2026-10-27) | 0 | none |
| Close | Disappears at once, no fade (Hussein, 2026-10-27) | 0 | none |
| Selection | Moves at once, no slide | 0 | none |
| Completion | Appears with each keystroke | 0 | none |
| Capsule | Pops in, holds 1.4 s, fades | 130 ms | strong ease-out |
| Reduce Motion | Capsule fades only, no pop | | |

## Copy

- Why line, top row taught: `Safari is first because you picked it for “sa” 9 times.` (`1 time` when singular)
- Why line, another row selected: `Opening this teaches “ma” to put Maps first.`
- Capsule after copying: `Copied 1,467.87`
- Completion that doesn't continue the typed text: `  →  Visual Studio Code`
- Nothing found: `Nothing matches “zzz”.`
- Unfinished sum: note "So far" with the value, or "Keep typing" when there is no value yet.
- Clock tray caption: `tea · 10 minutes · ends 12:39 AM`, `in 7 hours 1 minute`, `Running`, `No timers running`
- Clock tray prompt: `Add a length, like “timer 5m”` / `Add a time, like “alarm 7:30”`
- Capsule: `Timer set for 25 minutes`, `Alarm set for 7:30 AM`, `Stopwatch started`,
  `Stopwatch stopped at 1:23.4`, `Cancelled 25 min timer`
- Ring pill: `tea is done · 10 min`, `Timer done · 5 min`, `Alarm · 7:30 AM`, `2 timers are done`
