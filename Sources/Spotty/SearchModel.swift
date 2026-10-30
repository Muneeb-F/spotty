import AppKit
import LauncherCore
import Observation

/// What the panel shows under the field, exactly one at a time.
enum Tray: Equatable {
    /// Empty field: up to five recent apps, ⌘1 to ⌘5.
    case recent([AppEntry])
    /// A search: at most six rows.
    case apps([AppRow])
    /// A sum replaces the list entirely.
    case math(expression: String, outcome: CalcOutcome)
    /// "timer 5m", "alarm 7:30", "stopwatch": replaces the list like a sum does.
    case clock(ClockTray)
    /// "Nothing matches “zzz”."
    case nothing
}

/// What the clock tray shows.
enum ClockTray: Equatable {
    /// A timer or alarm ready to start: Return starts it.
    case start(ClockCommand)
    /// "stopwatch": Return starts one, or stops the one that's running.
    case stopwatch(running: ClockItem?, label: String?)
    /// The keyword alone: what's running as rows (Return stops the selected one) and a hint.
    case list(ClockKind, [ClockItem])
}

struct AppRow: Identifiable, Equatable {
    let app: AppEntry
    /// Times this query was taught this app, for the why line; 0 for every other row.
    let pickCount: Int
    /// `Character` offsets in `app.name` to draw at weight 600.
    let highlights: [Int]
    var id: String { app.id }
}

/// What Return (or ⌘↩, ⌘C, ⌘1–⌘5) asked for. The app delegate carries it out.
enum Activation {
    /// `query` is what was typed; opening any app for it teaches the query to put that app first.
    case launch(AppEntry, query: String, reveal: Bool)
    case copy(display: String, text: String)
    case startClock(ClockCommand)
    case stopClock(ClockItem)
}

@MainActor @Observable
final class SearchModel {
    var query = "" { didSet { if query != oldValue { refresh() } } }
    private(set) var tray: Tray = .recent([])
    var selection = 0 { didSet { if selection != oldValue { onContentChange?() } } }
    /// Bumped on every show; the view focuses the field.
    var focusRequest = 0
    /// True while an input method is composing, when the completion would only get in the way.
    var isComposing = false
    var index = AppIndex.empty { didSet { refresh() } }
    var usage = UsageStore()
    /// The running timers, alarms and stopwatch, for the clock tray.
    @ObservationIgnored var clocks: Clocks?
    @ObservationIgnored var onActivate: ((Activation) -> Void)?
    /// Told after every change to the tray or selection (the why line comes and goes with it),
    /// so the panel can resize before SwiftUI draws the change.
    @ObservationIgnored var onContentChange: (() -> Void)?

    func refresh() {
        let typed = QueryKeys(query)
        if !typed.isEmpty, let command = ClockCommand.parse(query) {
            tray = .clock(clockTray(command))
            selection = 0
            onContentChange?()
            return
        }
        let sum = Calculator.evaluate(query)
        if typed.isEmpty {
            // Ask for more than five, since a recent app may have been deleted since.
            tray = .recent(Array(usage.recent(limit: 10).compactMap(index.app(id:)).prefix(5)))
        } else if sum != .notMath {
            tray = .math(expression: Calculator.expressionLine(query), outcome: sum)
        } else {
            let rows = Ranker.rank(typed, index.searchables, usage: usage, now: .now).compactMap { r in
                index.app(id: r.item.id).map { AppRow(app: $0, pickCount: r.pickCount, highlights: r.highlights) }
            }
            tray = rows.isEmpty ? .nothing : .apps(rows)
        }
        selection = 0
        onContentChange?()
    }

    private func clockTray(_ command: ClockCommand) -> ClockTray {
        let board = clocks?.board ?? ClockBoard()
        switch command {
        case .timer, .alarm: return .start(command)
        case .stopwatch(let label): return .stopwatch(running: board.stopwatch, label: label)
        case .list(let kind): return .list(kind, board.items)
        }
    }

    var rowCount: Int {
        switch tray {
        case .recent(let apps): apps.count
        case .apps(let rows): rows.count
        case .clock(.list(_, let items)): items.count
        case .math, .clock, .nothing: 0
        }
    }

    /// Where the pointer was when the panel opened or last moved over it. Hover only selects a row
    /// once the pointer really moves, so a list changing under a resting pointer keeps row 1.
    @ObservationIgnored private var pointer: NSPoint?

    func notePointer() { pointer = NSEvent.mouseLocation }

    func hover(_ row: Int) {
        let location = NSEvent.mouseLocation
        guard location != pointer else { return }
        pointer = location
        if selection != row { selection = row }
    }

    func move(_ step: Int) {
        guard rowCount > 0 else { return }
        selection = (selection + step + rowCount) % rowCount
    }

    /// Grey text after the caret for the selected row. Tab accepts it.
    var ghost: Ranker.Completion {
        guard !isComposing, case .apps(let rows) = tray, rows.indices.contains(selection) else { return .none }
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

    func activateSelection(reveal: Bool = false) {
        switch tray {
        case .math(_, .value(_, let display, let copy)):
            onActivate?(.copy(display: display, text: copy))
        case .recent(let apps) where apps.indices.contains(selection):
            onActivate?(.launch(apps[selection], query: "", reveal: reveal))
        case .apps(let rows) where rows.indices.contains(selection):
            onActivate?(.launch(rows[selection].app, query: query, reveal: reveal))
        case .clock(.start(let command)):
            onActivate?(.startClock(command))
        case .clock(.stopwatch(let running?, _)):
            onActivate?(.stopClock(running))
        case .clock(.stopwatch(nil, let label)):
            onActivate?(.startClock(.stopwatch(label: label)))
        case .clock(.list(_, let items)) where items.indices.contains(selection):
            onActivate?(.stopClock(items[selection]))
        default:
            break  // an unfinished sum, an error, or no match: Return does nothing
        }
    }

    /// ⌘1–⌘5 while the field is empty. Returns false when there is no such recent app.
    func openRecent(_ number: Int) -> Bool {
        guard case .recent(let apps) = tray, apps.indices.contains(number - 1) else { return false }
        selection = number - 1
        activateSelection()
        return true
    }

    /// ⌘C copies a sum's result. Returns false when there is no result, so the field gets ⌘C.
    func copyResult() -> Bool {
        guard case .math(_, .value) = tray else { return false }
        activateSelection()
        return true
    }
}
