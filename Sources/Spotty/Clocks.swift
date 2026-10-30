import AppKit
import LauncherCore
import Observation
import SwiftUI

/// The running timers, alarms and stopwatch. Wakes only when the menu bar's figure changes or
/// something is due, and not at all while nothing runs.
@MainActor @Observable
final class Clocks {
    private(set) var board = ClockBoard()
    /// Moves on with every tick, so the menu bar redraws its figure.
    private(set) var now = Date()
    /// Told whenever something starts, stops or goes off.
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private let ringer = RingController()

    @discardableResult
    func start(_ command: ClockCommand) -> ClockItem? {
        let now = Date()
        let item: ClockItem
        switch command {
        case .timer(let seconds, let label):
            item = ClockItem(kind: .timer, label: label, start: now, end: now + TimeInterval(seconds))
        case .alarm(let date, let label):
            item = ClockItem(kind: .alarm, label: label, start: now, end: date)
        case .stopwatch(let label):
            guard board.stopwatch == nil else { return nil }  // one at a time
            item = ClockItem(kind: .stopwatch, label: label, start: now, end: nil)
        case .list:
            return nil
        }
        board.add(item)
        changed()
        return item
    }

    @discardableResult
    func stop(_ id: UUID) -> ClockItem? {
        let item = board.remove(id)
        if item != nil { changed() }
        return item
    }

    private func changed() {
        tick()
        onChange?()
    }

    private func tick() {
        ticker?.invalidate()
        ticker = nil
        now = .now
        let due = board.popDue(at: now)
        if !due.isEmpty {
            ringer.ring(due)
            onChange?()
        }
        guard let wait = board.nextTick(at: now) else { return }
        // A hair late rather than early, so the figure has really changed when it redraws.
        let timer = Timer(timeInterval: wait + 0.01, repeats: false) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    /// The menu bar's figure: the soonest timer or alarm, else the stopwatch in whole seconds.
    var menuBarText: String? {
        guard let item = board.headline else { return nil }
        if let left = item.remaining(at: now) { return ClockFormat.countdown(left) }
        return ClockFormat.stopwatchWhole(item.elapsed(at: now))
    }

    var menuBarSymbol: String {
        switch board.headline?.kind {
        case .alarm: "alarm"
        case .stopwatch: "stopwatch"
        default: "timer"
        }
    }
}

extension ClockKind {
    var symbol: String {
        switch self {
        case .timer: "timer"
        case .alarm: "alarm"
        case .stopwatch: "stopwatch"
        }
    }
}

/// Time of day for alarms, in the Mac's own style ("7:30 AM", "19:30").
func timeOfDay(_ date: Date) -> String {
    date.formatted(date: .omitted, time: .shortened)
}

/// The pill that says a timer or alarm went off. Unlike the capsule it stays until you click
/// Stop, and it chimes every two seconds for up to a minute.
@MainActor
final class RingController {
    private let panel: NSPanel
    private var ringing: [ClockItem] = []
    private var chime: Timer?
    private var chimes = 0

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.level = .modalPanel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.identifier = NSUserInterfaceItemIdentifier("ring")
    }

    func ring(_ items: [ClockItem]) {
        ringing += items
        let host = FirstClickHostingView(rootView: RingView(text: text, stop: { [weak self] in self?.stop() }))
        let size = host.fittingSize
        panel.contentView = host
        // Top centre of the screen with the pointer, just under the menu bar.
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(NSRect(x: (visible.midX - size.width / 2).rounded(), y: visible.maxY - 12 - size.height,
                              width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        chimes = 0
        playChime()
        chime?.invalidate()
        chime = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { self.playChime() }
        }
    }

    private func playChime() {
        chimes += 1
        if chimes > 30 { chime?.invalidate(); chime = nil; return }
        NSSound(named: "Glass")?.play()
    }

    func stop() {
        chime?.invalidate()
        chime = nil
        ringing = []
        panel.orderOut(nil)
    }

    /// "tea is done", "Alarm · 7:30 AM", or "3 timers are done".
    private var text: String {
        guard ringing.count == 1, let item = ringing.first else {
            return ringing.allSatisfy { $0.kind == .alarm } ? "\(ringing.count) alarms went off" : "\(ringing.count) timers are done"
        }
        switch item.kind {
        case .alarm:
            let time = item.end.map(timeOfDay) ?? ""
            return item.label.map { "\($0) · \(time)" } ?? "Alarm · \(time)"
        default:
            return item.label.map { "\($0) is done · \(ClockFormat.short(item.duration ?? 0))" }
                ?? "Timer done · \(ClockFormat.short(item.duration ?? 0))"
        }
    }
}

/// Takes the first click even though the panel isn't key, so Stop works in one click.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct RingView: View {
    let text: String
    let stop: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bell.fill").foregroundStyle(Quiet.indigo)
            Text(text).foregroundStyle(Quiet.ink1).lineLimit(1).fixedSize().layoutPriority(1)
            Button(action: stop) {
                Text("Stop")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Quiet.onAccent)
                    .padding(.horizontal, 14)
                    .frame(height: 26)
                    .fixedSize()
                    .background(Quiet.accent.opacity(hovered ? 0.85 : 1), in: .capsule)
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.leading, 16)
        .padding(.trailing, 5)
        .frame(height: 36)
        .background(Quiet.plate, in: .capsule)
        .overlay(Capsule().strokeBorder(Quiet.panelRing, lineWidth: 0.5))
        .padding(1)
        .fixedSize()
    }
}
