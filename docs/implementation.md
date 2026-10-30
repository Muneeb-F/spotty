# Spotlight replacement: how it works

Oct 26, 2026 · @Hussein

## At a glance

SwiftUI draws everything you see. A thin layer of AppKit and Carbon, around 150 lines, does the jobs SwiftUI has no API for, and all the logic (matching, ranking, math) is plain Swift with no UI imports so it can be unit-tested on its own.

It follows **B · Quiet**, the design you picked on the [Launcher design directions](https://claude.ai/artifact/3roF8v8c79ZPXBPbg9wJ19) canvas. The field opens on your five recent apps, a search shows at most six rows with the matched letters in bold, Tab accepts a grey completion, a line under the list explains why the top app is first, and a sum replaces the list with one large result. The core code below was changed to match and re-tested.

| Part | Built with | Why |
| --- | --- | --- |
| Search field, result rows, settings window | SwiftUI | The whole visible UI |
| The floating panel itself | AppKit `NSPanel`, hosting the SwiftUI view through `NSHostingView` | A SwiftUI window always activates your app, so the app you were in would lose focus and its menu bar. A non-activating `NSPanel` doesn't |
| Global hotkey | Carbon `RegisterEventHotKey` | Neither SwiftUI nor AppKit has a global-shortcut API |
| Finding apps | Foundation `FileManager` and `Bundle` | Plain file reads |
| Watching app folders | CoreServices FSEvents | The system's change feed for folders |
| Launching, icons, clipboard | AppKit `NSWorkspace`, `NSPasteboard` | System services, not UI |
| Matching, ranking, calculator | Plain Swift, Foundation only | Tested with `swift test` in milliseconds, no app launch needed |

**Project layout**

- `LauncherCore` (a local Swift package, Foundation only): `SearchKeys` (folding and word splitting), `Matcher`, `Usage` (`DecayingCounter`, `UsageStore`), `Ranker`, and the `Calc` folder (`Lexer`, `Parser`, `Evaluator`, `Formatter`, `Calculator`). It is already written and tested; see the last section.
- The app target: `LauncherApp` (the `@main` SwiftUI `App`), `AppDelegate`, `HotKey`, `LauncherPanel`, `AppScanner`, `AppIndex`, `FolderWatcher`, `SearchModel`, `SearchView`, `Actions`.
- The `App` struct declares only a `Settings` scene. `AppDelegate` (attached with `@NSApplicationDelegateAdaptor`) creates the panel and hotkey at launch, and `LSUIElement = YES` in Info.plist hides the Dock icon.

## Data model

A few small value types carry everything: what the scanner found on disk, what the matcher compares against, and what the panel shows under the field.

```swift
// App target: one installed app, as the scanner found it.
struct AppEntry: Identifiable, Sendable {
    let id: String            // bundle ID: stable across moves, renames and updates
    let name: String          // localized display name, without ".app"
    let url: URL              // resolved bundle path
    let otherNames: [String]  // CFBundleAlternateNames, plus the file name when it differs
    let modified: Date        // bundle's modification date; unchanged means skip re-reading it
}

// LauncherCore: an item the matcher can rank. Keys are built once, never per keystroke.
public struct Searchable {
    public let id: String
    public let name: String
    public let keys: [SearchKeys]  // display name first, then other names and your aliases
}

// App target: what the panel shows under the field, exactly one at a time.
enum Tray {
    case recent([AppEntry])                              // empty field: five recent apps, ⌘1 to ⌘5
    case apps([AppRow])                                  // a search: at most six rows
    case math(expression: String, outcome: CalcOutcome)  // a sum replaces the list entirely
    case nothing                                         // "No apps match"
}

struct AppRow: Identifiable {
    let app: AppEntry
    let pickCount: Int     // for the why line; 0 unless this query was taught this app
    let highlights: [Int]  // character offsets in app.name to draw at weight 600
    var id: String { app.id }
}
```

- **Identity is the bundle ID.** Learned ranking and aliases are keyed by it, so they survive an app moving folders or updating itself.
- **The index is one immutable array.** The scanner builds a complete new `[AppEntry]` plus its `[Searchable]` off the main thread, and the main thread swaps both in at once. A keystroke never sees a half-built index and nothing needs a lock.
- **Keys are Unicode scalar arrays**, not `String`. Comparing Swift `Character`s runs grapheme-cluster logic on every comparison; folded scalars compare as plain integers, which is most of why ranking takes a quarter of a millisecond.

## Indexing apps

Indexing is a plain folder walk: list a fixed set of folders, keep every `.app` bundle, read its ID and names, and skip any bundle whose modification date hasn't moved since the last scan. It never asks Spotlight and never loads an icon.

**1. Collect candidates.** Walk each root one level deep, skipping hidden files:

| Root | Note |
| --- | --- |
| `/Applications`, `~/Applications` | One subfolder deep, which covers `Utilities`, vendor folders like `Adobe Photoshop 2026/`, and Setapp |
| `/System/Applications` and its `Utilities` | Apple's apps |
| `/System/Volumes/Preboot/Cryptexes/App/System/Applications` | Safari. The `/Applications/Safari.app` entry is a hidden link, so it is skipped and this folder is scanned instead |
| `/System/Library/CoreServices/Applications` | Keychain Access, Archive Utility and friends |
| `/System/Library/CoreServices/Finder.app` | A single bundle, added directly |
| `Contents/Developer/Applications` inside any Xcode found | Simulator, Instruments |

An entry ending in `.app` is a candidate. A plain folder is walked one more level. A symlink or Finder alias is resolved, and dropped if it dangles (uninstallers leave these behind).

**2. Read each bundle, cheaply.** Resolve the path. If the previous scan has this path with the same `contentModificationDate`, reuse that entry and touch nothing else. Otherwise:

- Read `Contents/Info.plist` directly with `PropertyListSerialization`, not through `Bundle(url:)`. `Bundle` keeps one cached instance per path for the life of your process, so after an app updates itself you would keep seeing its old Info.plist ([JUCE forum](https://forum.juce.com/t/file-getversion-uses-cached-data-on-macos/55452), [Michel Fortin](https://michelf.ca/blog/2010/pref-pane-update-problem/)).
- Skip bundles with no `CFBundleIdentifier`, and helpers with `LSBackgroundOnly` set.
- Display name: the URL's `localizedNameKey` resource value, which is Finder's name for it in your language, minus a trailing ".app". Fall back to `CFBundleDisplayName`, then `CFBundleName`, then the file name.
- Other names: `CFBundleAlternateNames` if present, plus the file name when it differs from the display name.

**3. De-duplicate.** Drop repeats of the same resolved path. When one bundle ID shows up twice (a copy in `/Applications` and another in `~/Applications`), keep the newer one as the result and the other only as a fallback. When two different apps share a display name, show their folder as a grey subtitle.

**4. Build search keys and publish.** Aliases from `aliases.json` are merged in here, keyed by bundle ID, so editing an alias never needs a disk scan. Build every `Searchable` in the same background task, then hand the finished arrays to the main actor in one assignment.

**5. Icons, later and lazily.** A row asks an `IconCache` (an `NSCache` keyed by path plus modification date) for its icon. On a miss it calls `NSWorkspace.shared.icon(forFile:)`. Only the visible rows, six at most, ever load icons.

```swift
// App target, macOS only. Sketch: not compiled here, since AppKit doesn't exist on Linux.
static func read(_ url: URL, modified: Date) -> AppEntry? {
    let plistURL = url.appendingPathComponent("Contents/Info.plist")
    guard let data = try? Data(contentsOf: plistURL),
          let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let id = info["CFBundleIdentifier"] as? String,
          info["LSBackgroundOnly"] as? Bool != true
    else { return nil }
    var name = (try? url.resourceValues(forKeys: [.localizedNameKey]))?.localizedName
        ?? info["CFBundleDisplayName"] as? String ?? url.lastPathComponent
    if name.hasSuffix(".app") { name.removeLast(4) }
    var others = info["CFBundleAlternateNames"] as? [String] ?? []
    let fileName = url.deletingPathExtension().lastPathComponent
    if fileName != name { others.append(fileName) }
    return AppEntry(id: id, name: name, url: url, otherNames: others, modified: modified)
}
```

Expect a cold scan of about 300 apps to take well under the 200 ms budget, since it is a few hundred small plist reads; warm rescans are mostly `stat` calls. Wrap the scan in an `os_signpost` interval and check it in Instruments rather than trusting this estimate.

## Re-indexing

There is only one way the index changes: a full rescan in the background, made cheap by the modification-date cache, followed by one swap on the main thread. Five events can start it.

&#91;embedded content: re-indexing · 6 triggers, 1 rescan path\]

Only the alias file skips the disk entirely; every other trigger runs the same rescan, so there is one code path to get right.

- **FSEvents, on user folders only.** Watch `/Applications` and `~/Applications`. The `/System` paths sit on the read-only, sealed system volume and only change with an OS update, which means a reboot and therefore a launch scan. Directory-level events are enough (no per-file flag), because the scan doesn't need to know what changed.
- **Let FSEvents do the debouncing.** The `latency` argument of `FSEventStreamCreate` (1.0 seconds) coalesces an installer's burst of thousands of writes into one callback, so there's no timer of your own.
- **Restart the stream on wake.** Observe `NSWorkspace.didWakeNotification`, stop and recreate the stream, then rescan. Sol does exactly this, which is a strong hint streams can go quiet across sleep.
- **A cheap check when the panel opens.** If the last scan is over a minute old, compare each root folder's modification date with the one recorded at that scan. Adding, removing or renaming an app changes it. Eight `stat` calls cost microseconds and cover a missed event.
- **One scan at a time.** If a trigger fires mid-scan, set a "dirty" flag and run once more when the current scan finishes, rather than starting a second scan in parallel.

```swift
// App target, macOS only. Sketch: not compiled here.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) { self.onChange = onChange }

    func start(_ paths: [String]) {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            Unmanaged<FolderWatcher>.fromOpaque(info!).takeUnretainedValue().onChange()
        }
        stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                     1.0,  // seconds of coalescing
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone))
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
```

## Matching

Matching answers one question per app: how strongly does what you typed hit this name? It returns a tier (which kind of hit) and a shape score from 0 to 100 (how good a hit of that kind), and ranking decides the order afterwards.

**Preparing names, once per scan** (`SearchKeys`):

1. Split the display name into words at spaces and punctuation, at camelCase humps (`TablePlus`), after an acronym (`HTTPToolkit` becomes HTTP, Toolkit), and between letters and digits (`1Password` becomes 1, Password).
2. Fold each word: lowercase, accents removed, width-insensitive, with no locale, so `Système Préférences` is `systeme preferences` and a Turkish "I" can't break anything.
3. Store the words glued together (`visualstudiocode`), a flag for each position that starts a word, the word offsets, and the initials (`vsc`).

The query gets the same folding per keystroke, both with spaces removed (for most tiers) and split on spaces (for "vis code").

**The six tiers**, checked in order; the first that hits wins:

| Tier | Rule | Example | Shape score favours |
| --- | --- | --- | --- |
| Exact | Query equals the whole name | `notes` for Notes | Always 100 |
| Prefix | Name starts with the query | `saf` for Safari, `1pass` for 1Password | Shorter names |
| Word prefix | A later word starts with it, or each query word starts a later word in order | `code`, `vis code` for Visual Studio Code | Earlier words, shorter names |
| Initials | Initials start with the query | `vsc`, `ft` for FaceTime | Using up more of the initials |
| Substring | Query appears anywhere | `tudio` | Earlier position |
| Fuzzy | Query letters appear in order, with gaps | `vstdo` | Word starts and unbroken runs |

Exact through Initials are "strong" tiers: learned usage may reorder them among each other. Substring and Fuzzy are "weak" and always rank below every strong match.

**The fuzzy scorer** is the only real algorithm here. Each matched letter earns 16 points, plus 10 if it starts a word and 6 if it directly follows the previous matched letter. Opening a gap costs 3 and each further skipped letter costs 1. Dynamic programming finds the best alignment rather than the first one, in about query length times name length steps:

```swift
// LauncherCore/Matcher.swift (compiled and tested)
// Ranking calls it as fuzzyScore, which is fuzzyAlign(q, name, trackPath: false)?.score.
static func fuzzyAlign(_ q: [Unicode.Scalar], _ name: SearchKeys,
                       trackPath: Bool = true) -> (score: Int, path: [Int])? {
    let c = name.compact, n = c.count
    let base = { (j: Int) in matchPoints + (name.wordStarts[j] ? wordStartBonus : 0) }
    // prev[j]: best score with the previous query character matched at j.
    // from[i][j]: where query character i - 1 sat in that best alignment.
    var prev = [Int?](repeating: nil, count: n)
    // Only kept for the few visible rows; ranking every app skips it.
    var from = trackPath ? [[Int]](repeating: [Int](repeating: -1, count: n), count: q.count) : []
    for j in 0..<n where c[j] == q[0] {
        prev[j] = base(j) - min(j, leadingLimit)
    }
    for i in q.indices.dropFirst() {
        var cur = [Int?](repeating: nil, count: n)
        var run: Int? = nil  // best prev[k] minus its gap cost, over k <= j - 2
        var runFrom = -1
        for j in 1..<n {
            if let r = run { run = r - gapExtend }
            if j >= 2, let p = prev[j - 2], p - gapStart > (run ?? Int.min) {
                run = p - gapStart
                runFrom = j - 2
            }
            guard c[j] == q[i] else { continue }
            let consecutive = prev[j - 1].map { $0 + consecutiveBonus }
            if let a = consecutive, a >= (run ?? Int.min) {
                cur[j] = a + base(j)
                if trackPath { from[i][j] = j - 1 }
            } else if let r = run {
                cur[j] = r + base(j)
                if trackPath { from[i][j] = runFrom }
            }
        }
        prev = cur
    }
    guard let end = prev.indices.filter({ prev[$0] != nil }).max(by: { prev[$0]! < prev[$1]! }) else { return nil }
    var path = [end]
    for i in stride(from: q.count - 1, to: 0, by: -1) where trackPath {
        path.insert(from[i][path[0]], at: 0)
    }
    return (prev[end]!, path)
}
```

The `run` variable is the trick that keeps it linear per row: moving one letter right makes every earlier gap one letter longer, so the best gapped option is just last step's best minus 1, compared with the newly reachable position. Typo tolerance (edit distance) is left out on purpose; the fuzzy tier already forgives skipped letters, and true typos are rarer in a launcher than in a document search.

**Bold letters.** Each visible row draws the letters that matched at weight 600, as the design does. `Matcher.highlights` replays the winning tier: the first letters for a prefix, the matched word for a word prefix, one letter per word for initials, and for fuzzy the alignment itself, which the scorer traces back through its `from` table. Ranking all the apps skips that bookkeeping; only the six rows on screen pay for it. A `charOffsets` table maps each folded letter back to its character in the real name, so the `é` in `Système Préférences` is the letter that turns bold. When an alias matched instead of the name, nothing is bold.

## Ranking and learning

Results are sorted into three bands: the app this exact query was taught to open, then strong matches, then weak matches. Learning uses a decaying launch counter, so old habits fade on their own, and one remembered choice per query, which is also what the why line under the list reports.

**The decaying counter.** Each counter stores just a value and the time it was last updated. Reading it applies the decay since then, and adding to it decays first, then adds:

```swift
// LauncherCore/Usage.swift (compiled and tested)
public struct DecayingCounter: Codable, Sendable, Equatable {
    public private(set) var value: Double
    public private(set) var updatedAt: Date

    public func value(at now: Date, halfLife: TimeInterval) -> Double {
        let age = max(0, now.timeIntervalSince(updatedAt))
        return value * pow(0.5, age / halfLife)
    }

    public mutating func add(_ amount: Double = 1, at now: Date, halfLife: TimeInterval) {
        value = value(at: now, halfLife: halfLife) + amount
        updatedAt = now
    }
}
```

**Three signals** live in `UsageStore`, one JSON file:

| Signal | Key | Fades | What it fixes |
| --- | --- | --- | --- |
| Taught pick | Folded query | Forgotten after 90 days without being chosen | `s` opening the wrong app: one choice is enough, and its count feeds the why line |
| Frecency | Bundle ID | Halves every 14 days | Ties and near-ties between apps you use a lot and apps you never open |
| Recent | Bundle ID | Keeps the newest 50 | The five apps an empty field lists |

Each query remembers one app, a count and when you last chose it, keyed by the folded query (so ` S  ` and `s` are the same key). Choosing the same app again adds 1. Choosing a different one replaces it with a count of 1, and `recordLaunch` returns true so the panel can show the capsule "“ma” now opens Maps first." The store keeps at most 500 queries and drops to the 400 used most recently when it overflows. Recent apps are noted on every launch from the panel, and also when an app comes to the front some other way (`NSWorkspace.didActivateApplicationNotification`), so the list matches what you actually use.

**The final order** (`Ranker.rank`):

1. **Band 0, the taught app:** the one app this exact query opens first, if it matches at all and you chose it in the last 90 days. This beats any tier, so after choosing Visual Studio Code for `code` once, it wins over CodeRunner from then on.
2. **Band 1, strong matches:** sorted by tier base + shape + frecency, where the tier bases are Exact 300, Prefix 200, Word prefix 160 and Initials 150, and frecency adds 20 points per doubling of recent launches, capped at 90 (`20 × log2(1 + launches)`).
3. **Band 2, weak matches:** substring before fuzzy, then shape + frecency.
4. Ties go to the shorter name, then alphabetical order.

Those weights were tuned against the tests rather than guessed, and these behaviours are now pinned down by them:

- With no history, `s` shows Slack (the shortest prefix match). One pick of Safari for `s` makes Safari first; it still is 60 days later, and after 180 unused days it is back to Slack. Choosing Maps twice for `ma` puts it first with a count of 2 (the why line's "2 times"), and choosing Mail once then takes over with a count of 1.
- One launch of Visual Studio Code does not lift it over CodeRunner for `code`, but about ten days of daily launches do. This is the number to adjust if it feels too eager or too stubborn.
- An exact name match stays above any prefix match, even after 300 launches of the prefix app; the 90-point cap is what guarantees this.

**Cost:** ranking 541 apps takes about 0.21 ms per keystroke in a release build on this Linux test machine, against the 8 ms budget. It runs synchronously on the main thread, so Return always acts on results for exactly what is in the field.

## Calculator

The calculator is a four-stage pipeline, text to tokens to tree to number to text, and every stage can say "this isn't math" so app search carries on untouched. `Calculator.evaluate(_:)` runs all four on each keystroke.

1. **Lexer** (`lex`). Reads numbers (`1,234.5`, `.5`, `2.5e-3`), operators (`+ - * / ^ %`, plus `× ÷ − · √`), parentheses, and a fixed list of words: `pi π e sqrt abs round floor ceil ln log exp mod`, plus `sin cos tan asin acos atan sinh cosh tanh asinh acosh atanh` in radians. A `°` or `deg` after a number or bracket makes it degrees (`sin 30°`, `sin(30 deg)`); inverses answer in radians. Trig and hyperbolic results are rounded to 15 significant digits and snapped to 0 within 1e−12, so `sin 30°` is 0.5 and `cos 90°` is 0 rather than binary noise; `tan 90°` and `atanh(1)` say "Undefined". Any other word or symbol returns nil, which means "not math", so `safari` or `hello + 2` never parse. A comma is a thousands separator only when exactly three digits follow it. An `x` between a number and a digit is multiplication (`2x3`).
2. **Parser** (`Parser`, a Pratt parser). Builds a tree. Each operator has a binding power, and one loop keeps extending the left side while the next operator binds tighter than the caller allows. That single rule gives precedence and associativity without a grammar file.
3. **Evaluator.** Walks the tree in `Decimal`. Whole-number powers stay exact (`1.1^2` is exactly 1.21). Square roots, logarithms and fractional powers go through `Double` and come back via Swift's shortest round-trip text, so no binary noise digits sneak in.
4. **Formatter.** Rounds to 12 significant digits, trims trailing zeros, groups thousands with commas, and switches to `1e20` style outside 1e-6 to 1e15. The display uses a true minus sign (`−3`, `1e−9`) as the design draws it, while the copied text keeps a plain hyphen (`-3`) so other apps can parse it. It builds the string by hand rather than with `NumberFormatter`, so output doesn't depend on region settings.

**Binding powers** (higher binds tighter):

| Power | Operators | Effect |
| --- | --- | --- |
| 10 | `+ -` | Left to right |
| 20 | `* / mod`, implicit multiplication | `2pi`, `3(4+5)`, `2 sqrt 9` |
| 30 | Unary minus | `-2^2` is -4, as in maths |
| 35 | Functions without parentheses | `sqrt 16 + 9` is 13 |
| 40 | `^`, right to left | `2^3^2` is 512 |
| 50 | Postfix `%` | `50%` is 0.5 |

```swift
// LauncherCore/Calc/Parser.swift (compiled and tested), the heart of the parser
private mutating func expression(_ minPower: Int) throws(ParseError) -> Expr {
    var lhs = try prefix()  // a number, constant, function call, unary minus, or ( ... )
    while let token = next {
        switch token {
        case .op("%"):
            guard Self.postfix >= minPower else { return lhs }
            pos += 1
            lhs = .percent(lhs)
        case .op(let op):
            let (left, right) = Self.infixPowers(op)  // (10, 11) for +, (40, 40) for ^
            guard left >= minPower else { return lhs }
            pos += 1
            lhs = .binary(op, lhs, try expression(right))
        case .name("mod"):
            guard Self.multiplicative >= minPower else { return lhs }
            pos += 1
            lhs = .binary("m", lhs, try expression(Self.multiplicative + 1))
        case .name, .lparen:
            // Implicit multiplication. Never between two plain numbers, so "3 4" is not 12.
            guard Self.multiplicative >= minPower else { return lhs }
            lhs = .binary("*", lhs, try expression(Self.multiplicative + 1))
        case .number, .rparen:
            return lhs
        }
    }
    return lhs
}
```

**Percent** is a node of its own so the evaluator can see it: after `+` or `-` it means "of the left side" (`200 + 10%` is 220), and anywhere else it divides by 100 (`200 * 10%` is 20).

**What the panel shows** depends on the outcome:

| Outcome | When | Tray |
| --- | --- | --- |
| `notMath` | Unknown word, stray symbol, or no operation at all (`2`, `e`, `pi`, `1password`) | Apps, as normal |
| `incomplete(soFar:)` | Input ends where an operand is needed: `1299*1.13+`, `12*`, `(3+` | The expression line, then the value so far in ink-3 labelled "So far" (`1,467.87`), or "Keep typing" when there is none yet (`-`) |
| `value` | It computed | The expression line (`1,299 × 1.13`) over the 42 pt result; Return, ⌘C or the Copy button copies `1467.87` |
| `error` | `1/0`, `sqrt(-1)`, `ln(0)`, overflow | The expression line over the message, such as "Can't divide by zero" |

A sum replaces the app list entirely, as in the design, so Return can only mean "copy". The value so far comes from `valueSoFar`: drop whatever still waits for an operand at the end (operators, an open bracket, a function name), then evaluate the rest with any open brackets closed, so `(2+3` already shows 5 while you type. A bare constant never counts as math, otherwise typing `e` on the way to Excel would put 2.718 above it.

**The expression line** comes from `Calculator.expressionLine`, which re-spells the tokens rather than the raw text: `1299*1.13` reads `1,299 × 1.13`, `-2^2-sqrt 9` reads `−2^2 − √9`, and `12 x 3` reads `12 × 3`. The lexer keeps each token's original text, so `1.50` stays `1.50` while you type instead of jumping to `1.5`; only grouping commas are added.

**Tested examples** (42 result cases in all, plus copy text, value so far, expression line, error and not-math cases):

| Input | Result |
| --- | --- |
| `0.1 + 0.2` | 0.3 |
| `1/3` | 0.333333333333 |
| `(2+3` | 5 |
| `1,234.5 * 2` | 2,469 |
| `200 - 10%` | 180 |
| `sqrt(2)` | 1.41421356237 |
| `2pi` | 6.28318530718 |
| `-10 mod 3` | 2 |
| `10^20` | 1e20 |
| `12 × 3 ÷ 4` | 9 |
| -2^2 | −4 |
| 1299\*1.13+ | 1,467.87 so far |

## Timers, alarms and the stopwatch

`ClockCommand.parse` (in `LauncherCore/Clock`) runs before the calculator on every keystroke. It
needs a keyword as a whole word (`timer`, `alarm`, `stopwatch`, their plurals, or `stop watch`),
so `time`, `5m` or `7pm` alone stay app searches. After the keyword and any leading filler (`set a
… for`, `at`), it looks for the first run of words that reads as a length or a time of day; what's
left is the label (`tea timer 4m` is a 4 minute timer called "tea").

- **Lengths:** words are split where digits meet letters, so `1h30m` reads as `1 h 30 m`. Units are
  `h/hr/hour`, `m/min/minute` and `s/sec/second` with plurals; fractions work (`1.5h`). A number with
  no unit means minutes on its own and the next unit down after another (`1h 30`, `2m 15`). `4:30` is
  m:ss and `1:00:00` h:mm:ss. Up to 99 hours.
- **Times of day:** `7`, `7:30`, `7am`, `7:30 p.m.`, `19:00`, `noon`, `midnight`. With no am or pm
  and an hour from 1 to 12, the alarm goes for whichever of the two comes first.
- **No length or time** (`timer`, `alarm at`, `timer 100h`) gives `.list`, which shows what's running.

`ClockBoard` holds the running `ClockItem`s, soonest first and the stopwatch last, and hands back the
ones that are due. `ClockFormat` writes the figures by hand: countdowns round up, so a timer never
reads `0:00` before it goes off, and the stopwatch shows tenths.

In the app, `Clocks` owns the board. It doesn't poll: after each change it schedules one `Timer` for
the moment the menu bar's figure next changes (`ClockBoard.nextTick`), which is also never later than
the next thing due, and schedules nothing while the board is empty. Due items go to
`RingController`, a non-activating panel that takes the first click so Stop works at once, and plays
the system "Glass" sound every two seconds for at most 30 chimes. The panel's rows and figures
redraw themselves with `TimelineView`, so they don't depend on the ticker. Nothing is saved to disk.

`SPOTTY_SNAPSHOT='timer 2s⏎|/tmp/set.png;ring|/tmp/ring.png'` captures the pill in a debug build.

## The SwiftUI panel

One `@Observable` model holds the query, what the tray shows and the selection; one SwiftUI view draws them in the Quiet layout; and the `NSPanel` owner handles the three things SwiftUI doesn't do well here: arrow keys and Tab inside a text field, top-anchored resizing, and showing without activating the app.

**The model** recomputes everything synchronously whenever the query changes:

```swift
// App target. Sketch: not compiled here (SwiftUI isn't available on Linux).
@MainActor @Observable
final class SearchModel {
    var query = "" { didSet { refresh() } }
    private(set) var tray: Tray = .recent([])
    var selection = 0
    var focusRequest = 0                 // bumped on every show; the view focuses the field
    var index = AppIndex.empty           // replaced whole by the scanner
    var usage = UsageStore()
    var onHeightChange: ((CGFloat) -> Void)?

    func refresh() {
        let typed = QueryKeys(query)
        let sum = Calculator.evaluate(query)
        if typed.isEmpty {
            tray = .recent(usage.recent(limit: 5).compactMap(index.app(id:)))
        } else if sum != .notMath {
            tray = .math(expression: Calculator.expressionLine(query), outcome: sum)
        } else {
            let rows = Ranker.rank(typed, index.searchables, usage: usage, now: .now).compactMap { r in
                index.app(id: r.item.id).map { AppRow(app: $0, pickCount: r.pickCount, highlights: r.highlights) }
            }
            tray = rows.isEmpty ? .nothing : .apps(rows)
        }
        selection = 0
        onHeightChange?(height)
    }

    /// Grey text after the caret for the selected row. Tab accepts it.
    var ghost: Ranker.Completion {
        guard case .apps(let rows) = tray, rows.indices.contains(selection) else { return .none }
        return Ranker.completion(typed: query, name: rows[selection].app.name)
    }

    func acceptGhost() {
        switch ghost {
        case .suffix(let rest): query += rest
        case .replace(let name): query = name
        case .none: break
        }
    }

    /// The line under the list: why the top app is first, or what Return is about to teach.
    var why: String? {
        guard case .apps(let rows) = tray, rows.indices.contains(selection) else { return nil }
        let typed = query.trimmingCharacters(in: .whitespaces), row = rows[selection]
        if selection > 0 { return "Opening this teaches “\(typed)” to put \(row.app.name) first." }
        guard row.pickCount > 0 else { return nil }
        let times = row.pickCount == 1 ? "1 time" : "\(row.pickCount) times"
        return "\(row.app.name) is first because you picked it for “\(typed)” \(times)."
    }

    /// Panel height from the spec's sizes: padding 4 + 8, field 50, label 24, rows 34 + 1 apart.
    var height: CGFloat {
        let top: CGFloat = 4 + 50 + 24 + 8
        switch tray {
        case .recent(let apps): return top + CGFloat(apps.count) * 35
        case .apps(let rows): return top + CGFloat(rows.count) * 35 + (why == nil ? 0 : 22)
        case .math: return top + 120      // expression, 42 pt result, Copy button: tune on the Mac
        case .nothing: return top
        }
    }

    func move(_ step: Int) {
        let count = switch tray {
        case .recent(let apps): apps.count
        case .apps(let rows): rows.count
        case .math, .nothing: 0
        }
        guard count > 0 else { return }
        selection = (selection + step + count) % count
    }
}
```

**The view** follows the Quiet spec: a 560-wide opaque panel in the `panel` colour (not glass), a 50-tall field, a 24-tall section label, and at most six 34-tall rows, 1 apart. It is a plain stack rather than a `List`, because a `List` brings its own selection and focus handling, which fights the text field for the keyboard, and nothing here ever scrolls. The colours are the spec's tokens, added to the asset catalogue with their dark and light hex values.

```swift
// App target. Sketch: not compiled here.
struct SearchView: View {
    @Bindable var model: SearchModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            field
            switch model.tray {
            case .recent(let apps):
                SectionLabel("Recent")
                ForEach(Array(apps.enumerated()), id: \.element.id) { i, app in
                    AppRowView(app: app, name: AttributedString(app.name),
                               meta: "⌘\(i + 1)", selected: i == model.selection)
                }
            case .apps(let rows):
                SectionLabel("Apps", count: rows.count)
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                    AppRowView(app: row.app, name: emphasized(row.app.name, at: row.highlights),
                               meta: nil, selected: i == model.selection)
                }
                if let why = model.why { WhyLine(text: why) }  // 11 / 14 in ink-4, after a sparkle
            case .math(let expression, let outcome):
                SectionLabel("Math")
                MathTray(expression: expression, outcome: outcome)  // 42 pt result, "So far", Copy
            case .nothing:
                SectionLabel("No apps match")
            }
        }
        .padding(EdgeInsets(top: 4, leading: 8, bottom: 8, trailing: 8))
        .frame(width: 560)
        .background(Color("panel"), in: .rect(cornerRadius: 16))
        .onChange(of: model.focusRequest) { fieldFocused = true }
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color("ink-3"))
            ZStack(alignment: .leading) {
                // The completion: the typed text drawn invisibly, then the rest in ink-4.
                Text("\(Text(model.query).foregroundStyle(.clear))\(Text(ghostText).foregroundStyle(Color("ink-4")))")
                    .allowsHitTesting(false)
                TextField("Open an app or calculate", text: $model.query)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .onSubmit { model.activateSelection() }
            }
            .font(.system(size: 17, weight: .medium))
            .tracking(-0.2)
        }
        .frame(height: 50)
    }

    private var ghostText: String {
        switch model.ghost {
        case .suffix(let rest): rest
        case .replace(let name): "  →  " + name
        case .none: ""
        }
    }
}

/// Matched letters in ink-1 at weight 600; the rest of the name stays ink-2 at 400.
func emphasized(_ name: String, at offsets: [Int]) -> AttributedString {
    var text = AttributedString()
    for (i, c) in name.enumerated() {
        var piece = AttributedString(String(c))
        if offsets.contains(i) {
            piece.font = .system(size: 13, weight: .semibold)
            piece.foregroundColor = Color("ink-1")
        }
        text += piece
    }
    return text
}
```

The completion overlay only lines up if the invisible copy and the field use the same font and start at the same x, which `.plain` text fields do today. Check it on the Mac with a long name and with an input method active, and hide the ghost while `hasMarkedText()` is true.

**The panel owner** (in the app delegate) wires the rest:

- **Hosting:** `panel.contentView = NSHostingView(rootView: SearchView(model: model))`.
- **Keys:** an `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` monitor, as Sol uses, catches Up, Down, Tab, Esc, ⌘C and ⌘1 to ⌘5 before the text field's editor consumes them, and returns nil for the ones it handles. Tab accepts the grey completion, Esc clears the field and a second Esc closes, ⌘C copies a sum's result, and ⌘1 to ⌘5 open a recent app while the field is empty. It leaves every key alone while `hasMarkedText()` is true, so input methods work. Return goes through `.onSubmit`, which doesn't fire mid-composition.
- **No debouncing needed:** holding ⌘Space opens the panel once; Carbon doesn't repeat a registered hot key while it is held (checked by hand on macOS 27, 2026-10-27). A second Return or ⌘1–⌘5 can't launch twice, because the first closes the panel and later keys go to the app in front.
- **Sizing:** `onHeightChange` sets the height from `model.height` and moves the frame's origin down by the same amount, so the top edge stays put while the list grows. AppKit measures windows from the bottom-left corner, so without that the field would jump.
- **Show:** on the screen that has the pointer, centred and a third of the way down, with `makeKeyAndOrderFront(nil)` and then `model.focusRequest += 1`. It fades in and drops 4 pt over 120 ms, or only fades with Reduce Motion on. Never call `NSApp.activate`, which is what keeps the app you were in frontmost.
- **Hide:** a 90 ms fade and then `orderOut(nil)`, on a second Esc, on Return, or on losing key status. Clear the query so the next open starts on Recent again. If there is a capsule message, a second tiny borderless panel that ignores the mouse shows it in the panel's place, holds it 1.4 s and fades.

## Launching, copying and saving

Return does one of two things, records what you chose, and gets out of the way; disk writes happen after the panel is gone.

```swift
// App target. Sketch: not compiled here.
extension SearchModel {
    func activateSelection() {
        switch tray {
        case .math(_, .value(_, let display, let copy)):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(copy, forType: .string)  // "1467.87", never "1,467.87"
            hide(capsule: "Copied \(display)")
        case .recent(let apps) where apps.indices.contains(selection):
            launch(apps[selection])
        case .apps(let rows) where rows.indices.contains(selection):
            launch(rows[selection].app)
        default:
            return  // an unfinished sum, an error, or no match: Return does nothing
        }
    }

    private func launch(_ app: AppEntry) {
        let typed = query.trimmingCharacters(in: .whitespaces)  // read before hide() clears it
        let picked = selection
        // An empty query (a Recent row) only updates frecency and recents, never a pick.
        let taught = usage.recordLaunch(of: app.id, query: QueryKeys(typed), at: .now)
        hide(capsule: taught && picked > 0 ? "“\(typed)” now opens \(app.name) first." : "Opening \(app.name)")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: app.url, configuration: config) { _, error in
            if error != nil { Task { @MainActor in self.requestRescan() } }  // moved or deleted since the scan
        }
        usageFile.changed(usage, .soon)
    }
}
```

Cmd+Return calls `NSWorkspace.shared.activateFileViewerSelecting([app.url])` instead, to reveal the app in Finder.

**Files on disk**, all in `~/Library/Application Support/<your app name>/`:

| File | Contents | Written |
| --- | --- | --- |
| `usage.json` | `UsageStore`: launch counters, the taught app per query and recent apps, a few kilobytes | Two seconds after the last launch from the panel. App switches only touch Recent, so they are gathered into at most one write a minute (`SaveThrottle`). Pending changes are flushed on quit, sleep, log out and user switch; an unchanged file is not rewritten. Atomically, off the main thread |
| `aliases.json` | `{"com.microsoft.VSCode": ["vs", "editor"]}`, by bundle ID | By the Settings window; you can also edit it by hand |

A missing or unreadable file means "start empty", never a crash. Keep the previous good copy as `usage.json.bak` so a bad write loses at most one launch.

**Settings and quitting.** With no Dock icon there is no app menu, so add a SwiftUI `MenuBarExtra` with a `SettingsLink` and a Quit button. The `Settings` scene holds an "Open at login" toggle backed by `SMAppService.mainApp`, the alias editor, and a "Reset learned ranking" button. Call `NSApp.activate()` when the settings window opens, since it is an ordinary window that should come to the front.

## Testing, and what was verified

The matching, ranking and calculator code in this doc compiles and passes its tests; the AppKit and SwiftUI parts are careful sketches that still need a Mac to prove them.

**Verified here** with Swift 6.1.3 (the official Linux toolchain), in the `LauncherCore` package saved to the project files at `launcher-core/`. All 26 XCTest cases pass, with no compiler warnings:

- Word splitting and folding (`1Password`, `HTTPToolkit`, `Système Préférences`), every match tier, and which letters each tier draws in bold.
- 17 golden queries against a 41-app catalogue, from `saf` to `system pref`.
- Learning: one pick changes the top result, a pick beats a better tier, the latest choice wins and its count is reported for the why line, about ten days of daily use lifts a word-start match, an exact name survives 300 launches of a rival, and a pick is kept at 60 days and gone at 180. Also: six rows at most, recent apps in order and capped at 50, Tab completion, a JSON round trip, and decay that halves exactly per half-life.
- 42 calculator results, plus copy text, the value so far of unfinished sums, the expression line, and the not-math, error and precedence-tree cases.
- Speed: ranking 541 apps averages about 0.21 ms per keystroke in a release build.

**Not verified:** anything that imports AppKit, SwiftUI or CoreServices (the scanner, `FolderWatcher`, the panel, the model and the view). Also, `Decimal` rounding and string folding came from the Linux build of Foundation, so run `swift test` on your Mac once before trusting them there.

**Tests to add on the Mac**

- [ ] Scanner: build a temporary folder of fake `.app` bundles (just `Contents/Info.plist`) and check names, de-duplication, the one-level-deep rule, and the modification-date cache.
- [ ] Golden queries against your real `/Applications`, including `safari`, `finder` and `keychain`.
- [ ] Manual panel checks: over a full-screen app, on a second display, with Stage Manager on, with a Japanese input method, and after sleep.

**Sources:** [JUCE forum on cached Info.plist data](https://forum.juce.com/t/file-getversion-uses-cached-data-on-macos/55452), [Michel Fortin on the same NSBundle caching](https://michelf.ca/blog/2010/pref-pane-update-problem/), and the [Sol](https://github.com/ospfranco/sol) and [Tinycast](https://github.com/abue-ammar/tinycast) source code read for the scope doc. Everything else comes from the [scope doc](https://claude.ai/artifact/PXxXeH3Nbj5pMpftWPmcKt) and its sources.
