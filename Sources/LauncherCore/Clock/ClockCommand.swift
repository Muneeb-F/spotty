import Foundation

/// The three kinds of clock Spotty keeps.
public enum ClockKind: String, Equatable, Sendable {
    case timer, alarm, stopwatch
}

/// What a query asks the clock for. Every command needs its keyword ("timer", "alarm",
/// "stopwatch") as a whole word, so ordinary app searches never turn into timers.
public enum ClockCommand: Equatable, Sendable {
    /// "timer 5m", "10 min timer tea", "timer 1:30", "set a timer for 1h 30".
    case timer(seconds: Int, label: String?)
    /// "alarm 7:30am", "alarm 19:00 standup": the next time the clock reads that.
    case alarm(at: Date, label: String?)
    /// "stopwatch": starts one, or stops the one that's running.
    case stopwatch(label: String?)
    /// The keyword with nothing usable after it yet ("timer", "alarm at", "timers"). The panel
    /// lists what's running and says what to type.
    case list(ClockKind)

    /// The longest timer Spotty sets: 99 hours.
    public static let maxTimer = 99 * 3600

    public static func parse(_ query: String, now: Date = .now, calendar: Calendar = .current) -> ClockCommand? {
        var words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let at = words.firstIndex(where: { keywords[$0.lowercased()] != nil }) else {
            // "stop watch" in two words.
            if let i = words.indices.dropLast().first(where: { words[$0].lowercased() == "stop" && words[$0 + 1].lowercased() == "watch" }) {
                words.replaceSubrange(i...(i + 1), with: ["stopwatch"])
                return parse(words.joined(separator: " "), now: now, calendar: calendar)
            }
            return nil
        }
        let kind = keywords[words[at].lowercased()]!
        words.remove(at: at)
        // Leading filler: "set a timer for 5 minutes", "start a stopwatch", "alarm at 7".
        while let first = words.first, fillers.contains(first.lowercased()) { words.removeFirst() }

        switch kind {
        case .stopwatch:
            return .stopwatch(label: label(words))
        case .timer:
            guard let (span, seconds) = findSpan(words, parse: duration), seconds <= maxTimer else { return .list(.timer) }
            words.removeSubrange(span)
            return .timer(seconds: seconds, label: label(words))
        case .alarm:
            guard let (span, time) = findSpan(words, parse: clockTime) else { return .list(.alarm) }
            words.removeSubrange(span)
            return .alarm(at: next(time, after: now, calendar: calendar), label: label(words))
        }
    }

    private static let keywords: [String: ClockKind] = [
        "timer": .timer, "timers": .timer, "alarm": .alarm, "alarms": .alarm,
        "stopwatch": .stopwatch, "stopwatches": .stopwatch,
    ]
    private static let fillers: Set<String> = ["set", "start", "new", "a", "an", "for", "at", "in", "me"]

    /// What's left after the keyword and the time, with "for"/"to" dropped from its front:
    /// "timer 20m for tea" is labelled "tea". Nil when nothing is left.
    private static func label(_ words: [String]) -> String? {
        var words = words[...]
        while let first = words.first, ["for", "to", "-", "–", "·"].contains(first.lowercased()) { words = words.dropFirst() }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    /// The first run of words, longest first, that `parse` accepts: in "tea 4 min" that's "4 min".
    private static func findSpan<T>(_ words: [String], parse: ([String]) -> T?) -> (Range<Int>, T)? {
        for start in words.indices {
            for end in stride(from: words.count, to: start, by: -1) {
                if let value = parse(Array(words[start..<end])) { return (start..<end, value) }
            }
        }
        return nil
    }

    // MARK: Durations

    /// "5m", "5 min", "1h30m", "1h 30" (30 minutes), "90s", "1.5h", "4:30" (m:ss), "1:00:00",
    /// or a bare number, which means minutes. Nil unless every word is part of it.
    static func duration(_ words: [String]) -> Int? {
        let pieces = words.flatMap(split)
        guard !pieces.isEmpty else { return nil }
        if pieces.count == 1, let clock = colonDuration(pieces[0]) { return clock > 0 ? clock : nil }
        var total = 0.0
        var lastUnit: Double?
        var i = 0
        while i < pieces.count {
            guard let number = Double(pieces[i]), number.isFinite, pieces[i].first != "." || pieces[i].count > 1 else { return nil }
            i += 1
            let unit: Double
            if i < pieces.count, let u = units[pieces[i].lowercased()] {
                unit = u
                i += 1
            } else {
                // No unit: minutes on its own, otherwise the next unit down ("1h 30", "2m 15").
                switch lastUnit {
                case nil: unit = 60
                case 3600: unit = 60
                case 60: unit = 1
                default: return nil
                }
                guard i == pieces.count else { return nil }
            }
            if let lastUnit, unit >= lastUnit { return nil }  // "5m 2h", "5m 5m"
            lastUnit = unit
            total += number * unit
        }
        let seconds = Int(total.rounded())
        return seconds > 0 ? seconds : nil
    }

    private static let units: [String: Double] = {
        var units: [String: Double] = [:]
        for w in ["h", "hr", "hrs", "hour", "hours"] { units[w] = 3600 }
        for w in ["m", "min", "mins", "minute", "minutes"] { units[w] = 60 }
        for w in ["s", "sec", "secs", "second", "seconds"] { units[w] = 1 }
        return units
    }()

    /// "4:30" is 4 minutes 30 seconds, "1:02:03" an hour, 2 minutes and 3 seconds.
    private static func colonDuration(_ text: String) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              parts.dropFirst().allSatisfy({ $0.count == 2 })
        else { return nil }
        let values = parts.compactMap { Int($0) }
        guard values.count == parts.count, values.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
        return values.reduce(0) { $0 * 60 + $1 }
    }

    /// Splits a word where digits meet letters: "1h30m" is ["1", "h", "30", "m"], "7:30am" is ["7:30", "am"].
    static func split(_ word: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        var numeric: Bool?
        for c in word.lowercased() {
            let isNumber = c.isASCII && (c.isNumber || c == "." || c == ":")
            if numeric != nil, numeric != isNumber {
                pieces.append(current)
                current = ""
            }
            numeric = isNumber
            current.append(c)
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    // MARK: Times of day

    /// A time of day. `pm` is nil when neither am nor pm was given and the hour could be either.
    struct ClockTime: Equatable {
        var hour: Int  // 0...23 once `pm` is known; 1...12 while it isn't
        var minute: Int
        var pm: Bool?
    }

    /// "7", "7:30", "7am", "7:30 pm", "19:00", "noon", "midnight". Nil unless every word is part of it.
    static func clockTime(_ words: [String]) -> ClockTime? {
        let pieces = words.map { $0.lowercased().replacingOccurrences(of: "a.m.", with: "am").replacingOccurrences(of: "p.m.", with: "pm") }
            .flatMap(split)
        switch pieces {
        case ["noon"], ["midday"]: return ClockTime(hour: 12, minute: 0, pm: false)
        case ["midnight"]: return ClockTime(hour: 0, minute: 0, pm: false)
        default: break
        }
        guard (1...2).contains(pieces.count) else { return nil }
        let meridiem: Bool?
        if pieces.count == 2 {
            switch pieces[1] {
            case "am", "a": meridiem = false
            case "pm", "p": meridiem = true
            default: return nil
            }
        } else {
            meridiem = nil
        }
        let parts = pieces[0].split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let hour = Int(parts[0]), parts[0].count <= 2
        else { return nil }
        var minute = 0
        if parts.count == 2 {
            guard parts[1].count == 2, let m = Int(parts[1]), m < 60 else { return nil }
            minute = m
        }
        if let meridiem {
            guard (1...12).contains(hour) else { return nil }
            return ClockTime(hour: hour % 12 + (meridiem ? 12 : 0), minute: minute, pm: false)
        }
        guard hour < 24 else { return nil }
        // "19:00" and "0:30" can only be one time; "7" or "7:30" could be morning or evening.
        return ClockTime(hour: hour, minute: minute, pm: (1...12).contains(hour) ? nil : false)
    }

    /// The next moment after `now` that the clock reads `time`; for "7:30" with no am or pm,
    /// whichever of 7:30 and 19:30 comes first.
    static func next(_ time: ClockTime, after now: Date, calendar: Calendar) -> Date {
        let hours = time.pm == nil ? [time.hour % 12, time.hour % 12 + 12] : [time.hour]
        return hours.compactMap { hour in
            calendar.nextDate(after: now, matching: DateComponents(hour: hour, minute: time.minute, second: 0),
                              matchingPolicy: .nextTime)
        }.min() ?? now
    }
}
