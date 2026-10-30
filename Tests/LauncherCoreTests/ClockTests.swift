import Foundation
import XCTest
@testable import LauncherCore

final class ClockTests: XCTestCase {
    let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// 2026-10-27 at the given time, UTC.
    func day(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: hour, minute: minute))!
    }

    func parse(_ query: String, at now: Date? = nil) -> ClockCommand? {
        ClockCommand.parse(query, now: now ?? day(10), calendar: calendar)
    }

    func testTimers() {
        let cases: [(String, Int, String?)] = [
            ("timer 5m", 300, nil), ("timer 5 min", 300, nil), ("timer 5 minutes", 300, nil),
            ("timer 5", 300, nil), ("5m timer", 300, nil), ("timer 90s", 90, nil), ("timer 90 sec", 90, nil),
            ("timer 1h30m", 5400, nil), ("timer 1h 30m", 5400, nil), ("timer 1h 30", 5400, nil),
            ("timer 2m 15", 135, nil), ("timer 1.5h", 5400, nil), ("timer 4:30", 270, nil),
            ("timer 1:00:00", 3600, nil), ("Timer 25M", 1500, nil), ("set a timer for 10 minutes", 600, nil),
            ("timer 10m tea", 600, "tea"), ("tea timer 4m", 240, "tea"), ("timer 20m for Pasta", 1200, "Pasta"),
            ("timer 10m round 2", 600, "round 2"), ("timer 1 hour", 3600, nil), ("timer 1m 30s", 90, nil),
        ]
        for (query, seconds, label) in cases {
            XCTAssertEqual(parse(query), .timer(seconds: seconds, label: label), "query \"\(query)\"")
        }
    }

    func testTimerWithoutALengthListsTimers() {
        for query in ["timer", "timers", "timer tea", "timer 0", "timer 100h", "timer 4:3", "set a timer"] {
            XCTAssertEqual(parse(query), .list(.timer), "query \"\(query)\"")
        }
    }

    func testOnlyTheKeywordMakesAClock() {
        for query in ["5m", "safari", "time", "tim", "timing", "1:30", "7pm", "watch", "stop", "2+2"] {
            XCTAssertNil(parse(query), "query \"\(query)\"")
        }
    }

    func testAlarms() {
        // It's 10:00.
        let cases: [(String, Date, String?)] = [
            ("alarm 10:30", day(10, 30), nil), ("alarm 7", day(19), nil), ("alarm 7am", day(7).addingTimeInterval(86400), nil),
            ("alarm 7 pm", day(19), nil), ("alarm 7:30pm", day(19, 30), nil), ("alarm 19:00", day(19), nil),
            ("alarm at 11", day(11), nil), ("alarm 0:15", day(0, 15).addingTimeInterval(86400), nil),
            ("alarm noon", day(12), nil), ("alarm midnight", day(0).addingTimeInterval(86400), nil),
            ("alarm 12am", day(0).addingTimeInterval(86400), nil), ("alarm 12pm", day(12), nil),
            ("alarm 9:45 standup", day(21, 45), "standup"), ("alarm 6:30 a.m.", day(6, 30).addingTimeInterval(86400), nil),
            ("alarm 10", day(22), nil),  // 10:00 now has gone, so the evening one
        ]
        for (query, date, label) in cases {
            XCTAssertEqual(parse(query), .alarm(at: date, label: label), "query \"\(query)\"")
        }
    }

    func testAlarmWithoutATimeListsAlarms() {
        for query in ["alarm", "alarms", "alarm at", "alarm 25:00", "alarm 7:60", "alarm 13pm"] {
            XCTAssertEqual(parse(query), .list(.alarm), "query \"\(query)\"")
        }
    }

    func testStopwatch() {
        XCTAssertEqual(parse("stopwatch"), .stopwatch(label: nil))
        XCTAssertEqual(parse("start a stopwatch"), .stopwatch(label: nil))
        XCTAssertEqual(parse("stop watch"), .stopwatch(label: nil))
        XCTAssertEqual(parse("stopwatch run"), .stopwatch(label: "run"))
    }

    func testFormats() {
        XCTAssertEqual(ClockFormat.countdown(300), "5:00")
        XCTAssertEqual(ClockFormat.countdown(299.2), "5:00", "rounds up, so it never reads 0:00 early")
        XCTAssertEqual(ClockFormat.countdown(0.4), "0:01")
        XCTAssertEqual(ClockFormat.countdown(3725), "1:02:05")
        XCTAssertEqual(ClockFormat.stopwatch(7.36), "0:07.3")
        XCTAssertEqual(ClockFormat.stopwatch(3600), "1:00:00.0")
        XCTAssertEqual(ClockFormat.spoken(300), "5 minutes")
        XCTAssertEqual(ClockFormat.spoken(5400), "1 hour 30 minutes")
        XCTAssertEqual(ClockFormat.spoken(61), "1 minute 1 second")
        XCTAssertEqual(ClockFormat.short(5400), "1 hr 30 min")
    }

    func testBoard() {
        let now = day(10)
        var board = ClockBoard()
        let watch = ClockItem(kind: .stopwatch, label: nil, start: now, end: nil)
        let long = ClockItem(kind: .timer, label: nil, start: now, end: now + 600)
        let short = ClockItem(kind: .timer, label: "tea", start: now, end: now + 240)
        let alarm = ClockItem(kind: .alarm, label: nil, start: now, end: now + 300)
        for item in [watch, long, short, alarm] { board.add(item) }
        XCTAssertEqual(board.items.map(\.id), [short.id, alarm.id, long.id, watch.id], "soonest first, stopwatch last")
        XCTAssertEqual(board.headline, short)
        XCTAssertEqual(long.title, "10 min timer")
        XCTAssertEqual(short.title, "tea")
        XCTAssertEqual(short.readout(at: now + 1.5), "3:59")

        XCTAssertEqual(board.popDue(at: now + 239), [])
        XCTAssertEqual(board.popDue(at: now + 301), [short, alarm])
        XCTAssertEqual(board.items, [long, watch])
        XCTAssertEqual(board.remove(watch.id), watch)
        XCTAssertNil(board.remove(watch.id))
        XCTAssertEqual(board.items, [long])
    }

    func testNextTickLandsOnTheSecond() {
        let now = day(10)
        var board = ClockBoard()
        XCTAssertNil(board.nextTick(at: now))
        board.add(ClockItem(kind: .timer, label: nil, start: now, end: now + 60.25))
        XCTAssertEqual(board.nextTick(at: now)!, 0.25, accuracy: 0.0001)
        XCTAssertEqual(board.nextTick(at: now + 0.25)!, 1, accuracy: 0.0001)
        XCTAssertEqual(board.nextTick(at: now + 60.1)!, 0.15, accuracy: 0.0001)

        var watch = ClockBoard()
        watch.add(ClockItem(kind: .stopwatch, label: nil, start: now, end: nil))
        XCTAssertEqual(watch.nextTick(at: now + 2.7)!, 0.3, accuracy: 0.0001)
    }
}
