import Foundation

/// A running timer, alarm or stopwatch.
public struct ClockItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let kind: ClockKind
    public let label: String?
    public let start: Date
    /// When a timer or alarm goes off; nil for a stopwatch.
    public let end: Date?

    public init(id: UUID = UUID(), kind: ClockKind, label: String?, start: Date, end: Date?) {
        self.id = id
        self.kind = kind
        self.label = label
        self.start = start
        self.end = end
    }

    /// A timer's length in whole seconds, as it was set.
    public var duration: Int? {
        guard kind == .timer, let end else { return nil }
        return Int(end.timeIntervalSince(start).rounded())
    }

    /// Seconds left before a timer or alarm goes off, never negative; nil for a stopwatch.
    public func remaining(at now: Date) -> TimeInterval? {
        end.map { max(0, $0.timeIntervalSince(now)) }
    }

    public func elapsed(at now: Date) -> TimeInterval { max(0, now.timeIntervalSince(start)) }

    /// What the item is called in rows, the menu and when it goes off: its label, or
    /// "5 min timer", "Alarm", "Stopwatch".
    public var title: String {
        if let label { return label }
        switch kind {
        case .timer: return "\(ClockFormat.short(duration ?? 0)) timer"
        case .alarm: return "Alarm"
        case .stopwatch: return "Stopwatch"
        }
    }

    /// The live figure: time left for timers and alarms, time so far for a stopwatch.
    public func readout(at now: Date) -> String {
        if let left = remaining(at: now) { return ClockFormat.countdown(left) }
        return ClockFormat.stopwatch(elapsed(at: now))
    }
}

/// Everything that's running, soonest first, stopwatches last. Pure, so the app's timer only
/// asks it what's due.
public struct ClockBoard: Equatable, Sendable {
    public private(set) var items: [ClockItem] = []

    public init() {}

    public var isEmpty: Bool { items.isEmpty }
    public var stopwatch: ClockItem? { items.first { $0.kind == .stopwatch } }
    public func items(of kind: ClockKind) -> [ClockItem] { items.filter { $0.kind == kind } }

    public mutating func add(_ item: ClockItem) {
        items.append(item)
        items.sort { a, b in
            switch (a.end, b.end) {
            case let (x?, y?): x < y
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): a.start < b.start
            }
        }
    }

    @discardableResult
    public mutating func remove(_ id: UUID) -> ClockItem? {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: i)
    }

    /// Takes off every timer and alarm whose time has come, soonest first.
    public mutating func popDue(at now: Date) -> [ClockItem] {
        let due = items.filter { $0.end.map { $0 <= now } ?? false }
        items.removeAll { $0.end.map { $0 <= now } ?? false }
        return due
    }

    /// The one item the menu bar shows: the soonest timer or alarm, else the stopwatch.
    public var headline: ClockItem? { items.first }

    /// How long to wait before the menu bar's figure next changes, or something goes off.
    public func nextTick(at now: Date) -> TimeInterval? {
        guard let first = items.first else { return nil }
        var wait: TimeInterval
        if let left = first.remaining(at: now) {
            // The countdown rounds up, so it changes as the time left crosses a whole second.
            let fraction = left - left.rounded(.down)
            wait = fraction > 0.001 ? fraction : 1
        } else {
            let elapsed = first.elapsed(at: now)
            wait = 1 - (elapsed - elapsed.rounded(.down))
        }
        // Something further down the list can't go off before the first one, since it's sorted.
        if let left = first.remaining(at: now) { wait = min(wait, max(left, 0.001)) }
        return max(wait, 0.001)
    }
}

/// How clock times are written. By hand, like the calculator, so they don't depend on region settings.
public enum ClockFormat {
    /// Time left, rounded up so a timer never shows 0:00 before it goes off: "4:59", "1:04:59", "0:09".
    public static func countdown(_ seconds: TimeInterval) -> String {
        clock(Int(seconds.rounded(.up)))
    }

    /// Time so far with tenths: "0:07.3", "12:01.0", "1:00:00.0".
    public static func stopwatch(_ seconds: TimeInterval) -> String {
        let tenths = Int((seconds * 10).rounded(.down))
        return "\(clock(tenths / 10)).\(tenths % 10)"
    }

    /// Time so far in whole seconds, for the menu bar: "0:07", "12:01".
    public static func stopwatchWhole(_ seconds: TimeInterval) -> String {
        clock(Int(seconds.rounded(.down)))
    }

    /// "5:00", "1:30:00".
    public static func clock(_ total: Int) -> String {
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        return h > 0 ? "\(h):\(two(m)):\(two(s))" : "\(m):\(two(s))"
    }

    /// "5 minutes", "1 hour 30 minutes", "1 minute 5 seconds".
    public static func spoken(_ total: Int) -> String {
        let parts = [(total / 3600, "hour"), (total / 60 % 60, "minute"), (total % 60, "second")]
            .filter { $0.0 > 0 }
            .map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
        return parts.isEmpty ? "0 seconds" : parts.joined(separator: " ")
    }

    /// "5 min", "1 hr 30 min", "45 sec", for titles.
    public static func short(_ total: Int) -> String {
        let parts = [(total / 3600, "hr"), (total / 60 % 60, "min"), (total % 60, "sec")]
            .filter { $0.0 > 0 }
            .map { "\($0.0) \($0.1)" }
        return parts.isEmpty ? "0 sec" : parts.joined(separator: " ")
    }
}
