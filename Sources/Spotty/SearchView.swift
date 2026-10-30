import LauncherCore
import SwiftUI

/// The "B · Quiet" panel: field, section label, then recent apps, matches or the math tray.
/// A plain stack rather than a `List`, whose own selection and focus would fight the field.
struct SearchView: View {
    @Bindable var model: SearchModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            field
            tray
        }
        .padding(EdgeInsets(top: 4, leading: 8, bottom: 8, trailing: 8))
        .frame(width: 560, alignment: .leading)
        .background(Quiet.panel, in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Quiet.panelRing, lineWidth: 0.5))
        .onChange(of: model.focusRequest) { fieldFocused = true }
    }

    // MARK: Field

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16))
                .foregroundStyle(Quiet.ink3)
            ZStack(alignment: .leading) {
                // The completion: the typed text drawn invisibly, then the rest in ink-4.
                Text("\(Text(model.query).foregroundStyle(.clear))\(Text(ghostText).foregroundStyle(Quiet.ink4))")
                    .lineLimit(1)
                    .allowsHitTesting(false)
                TextField("", text: $model.query, prompt: Text("Open an app or calculate").foregroundStyle(Quiet.ink4))
                    .textFieldStyle(.plain)
                    .foregroundStyle(Quiet.ink1)
                    .focused($fieldFocused)
            }
            .font(.system(size: 17, weight: .medium))
            .tracking(-0.2)
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
    }

    private var ghostText: String {
        switch model.ghost {
        case .suffix(let rest): rest
        case .replace(let name): "  →  " + name
        case .none: ""
        }
    }

    // MARK: Tray

    @ViewBuilder private var tray: some View {
        switch model.tray {
        case .recent(let apps) where !apps.isEmpty:
            SectionLabel(title: "Recent")
            rows(apps.enumerated().map { i, app in
                (app, AttributedString(app.name), "⌘\(i + 1)")
            })
        case .recent:
            EmptyView()
        case .apps(let found):
            SectionLabel(title: "Apps", count: found.count)
            rows(found.map { ($0.app, emphasized($0.app.name, at: $0.highlights), nil) })
            if let why = model.why { WhyLine(text: why) }
        case .math(let expression, let outcome):
            SectionLabel(title: "Math")
            MathTray(expression: expression, outcome: outcome) { model.activateSelection() }
        case .clock(.list(let kind, let items)) where !items.isEmpty:
            SectionLabel(title: "Running", count: items.count)
            clockRows(items)
            WhyLine(text: kind == .alarm ? "Add a time to set another, like “alarm 7:30”."
                                         : "Add a length to set another, like “timer 5m”.")
        case .clock(let clock):
            SectionLabel(title: clock.title)
            ClockTrayView(tray: clock) { model.activateSelection() }
        case .nothing:
            SectionLabel(title: "Nothing matches “\(model.query.trimmingCharacters(in: .whitespaces))”.")
        }
    }

    private func clockRows(_ items: [ClockItem]) -> some View {
        VStack(spacing: 1) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                ClockRowView(item: item, selected: i == model.selection)
                    .contentShape(.rect)
                    .onContinuousHover { phase in
                        if case .active = phase { model.hover(i) }
                    }
                    .onTapGesture {
                        model.selection = i
                        model.activateSelection()
                    }
            }
        }
    }

    private func rows(_ items: [(AppEntry, AttributedString, String?)]) -> some View {
        VStack(spacing: 1) {
            ForEach(Array(items.enumerated()), id: \.element.0.id) { i, item in
                AppRowView(app: item.0, name: item.1, meta: item.2, selected: i == model.selection)
                    .contentShape(.rect)
                    .onContinuousHover { phase in
                        if case .active = phase { model.hover(i) }
                    }
                    .onTapGesture {
                        model.selection = i
                        model.activateSelection()
                    }
            }
        }
    }
}

/// Matched letters in ink-1 at weight 600; the rest of the name keeps the row's style.
func emphasized(_ name: String, at offsets: [Int]) -> AttributedString {
    var text = AttributedString()
    let bold = Set(offsets)
    for (i, c) in name.enumerated() {
        var piece = AttributedString(String(c))
        if bold.contains(i) {
            piece.font = .system(size: 13, weight: .semibold)
            piece.foregroundColor = Quiet.ink1
        }
        text += piece
    }
    return text
}

private struct SectionLabel: View {
    let title: String
    var count: Int?

    var body: some View {
        HStack(spacing: 5) {
            Text(title).fontWeight(.medium).foregroundStyle(Quiet.ink3)
            if let count { Text("\(count)").foregroundStyle(Quiet.ink2) }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .frame(height: 24)
    }
}

private struct AppRowView: View {
    let app: AppEntry
    let name: AttributedString
    let meta: String?
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: IconCache.icon(for: app))
                .resizable()
                .frame(width: 22, height: 22)
            HStack(spacing: 6) {
                Text(name).foregroundStyle(selected ? Quiet.ink1 : Quiet.ink2)
                if let subtitle = app.subtitle { Text(subtitle).foregroundStyle(Quiet.ink4) }
            }
            .font(.system(size: 13))
            .lineLimit(1)
            Spacer(minLength: 8)
            if let meta {
                Text(meta).font(.system(size: 11.5)).foregroundStyle(Quiet.ink4)
            }
            if selected { Keycap(text: "↩") }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 10).fill(Quiet.fillSelected)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Quiet.ringSelected, lineWidth: 1))
            }
        }
    }
}

private struct Keycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Quiet.ink3)
            .frame(minWidth: 18, minHeight: 18)
            .background(Quiet.fillQuiet, in: .rect(cornerRadius: 5))
    }
}

private struct WhyLine: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkle").foregroundStyle(Quiet.indigo)
            Text(text).foregroundStyle(Quiet.ink4).lineLimit(1)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .frame(height: 22, alignment: .bottom)
    }
}

private struct MathTray: View {
    let expression: String
    let outcome: CalcOutcome
    let copy: () -> Void
    @State private var copyHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(expression)
                .font(.system(size: 12))
                .foregroundStyle(Quiet.ink3)
                .lineLimit(1)
            HStack(alignment: .bottom) {
                result
                Spacer(minLength: 12)
                if case .value = outcome {
                    Button(action: copy) {
                        HStack(spacing: 5) { Text("Copy"); Text("↩") }
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Quiet.onAccent)
                            .padding(.horizontal, 14)
                            .frame(height: 30)
                            .background(Quiet.accent.opacity(copyHovered ? 0.85 : 1), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .onHover { copyHovered = $0 }
                    .padding(.bottom, 4)
                }
            }
            .frame(height: 46)  // 42 / 46 whatever the state, so the panel doesn't jump while you type
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 14, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Quiet.wash, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Quiet.washRing, lineWidth: 0.5))
    }

    @ViewBuilder private var result: some View {
        switch outcome {
        case .value(_, let display, _):
            Text(separated(display))
                .font(.system(size: 42, weight: .semibold))
                .tracking(-1.47)
                .foregroundStyle(Quiet.ink1)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        case .incomplete(let soFar):
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                if let soFar {
                    Text(separated(soFar))
                        .font(.system(size: 42, weight: .semibold))
                        .tracking(-1.47)
                        .foregroundStyle(Quiet.ink3)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text("So far").font(.system(size: 11.5)).foregroundStyle(Quiet.ink4)
                } else {
                    Text("Keep typing")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Quiet.ink3)
                }
            }
        case .error(let error):
            Text(error.message)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Quiet.ink3)
        case .notMath:
            EmptyView()
        }
    }

    /// The result with its `,` and `.` in ink-4, as the design draws them.
    private func separated(_ text: String) -> AttributedString {
        var out = AttributedString()
        for c in text {
            var piece = AttributedString(String(c))
            if c == "," || c == "." { piece.foregroundColor = Quiet.ink4 }
            out += piece
        }
        return out
    }
}

extension ClockTray {
    var title: String {
        switch self {
        case .start(.alarm): "Alarm"
        case .start: "Timer"
        case .stopwatch: "Stopwatch"
        case .list(.alarm, _): "Alarm"
        case .list(.stopwatch, _): "Stopwatch"
        case .list: "Timer"
        }
    }
}

/// A running timer, alarm or stopwatch: its icon, title and live figure. Return stops it.
private struct ClockRowView: View {
    let item: ClockItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.kind.symbol)
                .font(.system(size: 15))
                .foregroundStyle(Quiet.ink3)
                .frame(width: 22, height: 22)
            HStack(spacing: 6) {
                Text(item.title).foregroundStyle(selected ? Quiet.ink1 : Quiet.ink2)
                if item.kind == .alarm, let end = item.end { Text(timeOfDay(end)).foregroundStyle(Quiet.ink4) }
            }
            .font(.system(size: 13))
            .lineLimit(1)
            Spacer(minLength: 8)
            TimelineView(.periodic(from: .now, by: item.kind == .stopwatch ? 0.1 : 1)) { context in
                Text(item.readout(at: context.date))
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(Quiet.ink4)
            }
            if selected { Keycap(text: "Stop ↩") }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 10).fill(Quiet.fillSelected)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Quiet.ringSelected, lineWidth: 1))
            }
        }
    }
}

/// The math tray's twin for clocks: a caption, a 42 pt figure and one filled button.
private struct ClockTrayView: View {
    let tray: ClockTray
    let act: () -> Void
    @State private var buttonHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(caption(at: context.date))
                    .font(.system(size: 12))
                    .foregroundStyle(Quiet.ink3)
                    .lineLimit(1)
            }
            HStack(alignment: .bottom) {
                figure
                Spacer(minLength: 12)
                if let action {
                    Button(action: act) {
                        HStack(spacing: 5) { Text(action); Text("↩") }
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Quiet.onAccent)
                            .padding(.horizontal, 14)
                            .frame(height: 30)
                            .background(Quiet.accent.opacity(buttonHovered ? 0.85 : 1), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .onHover { buttonHovered = $0 }
                    .padding(.bottom, 4)
                }
            }
            .frame(height: 46)
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 14, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Quiet.wash, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Quiet.washRing, lineWidth: 0.5))
    }

    private var action: String? {
        switch tray {
        case .start(.alarm): "Set"
        case .start: "Start"
        case .stopwatch(let running, _): running == nil ? "Start" : "Stop"
        case .list: nil
        }
    }

    private func caption(at now: Date) -> String {
        switch tray {
        case .start(.timer(let seconds, let label)):
            let ends = "ends \(timeOfDay(now + TimeInterval(seconds)))"
            return [label, ClockFormat.spoken(seconds), ends].compactMap { $0 }.joined(separator: " · ")
        case .start(.alarm(let date, let label)):
            let left = "in \(ClockFormat.spoken(Int((date.timeIntervalSince(now) / 60).rounded(.up)) * 60))"
            return [label, left].compactMap { $0 }.joined(separator: " · ")
        case .stopwatch(let running?, _):
            return [running.label, "Running"].compactMap { $0 }.joined(separator: " · ")
        case .stopwatch(nil, let label):
            return label ?? "Counts up from zero"
        case .list(.alarm, _):
            return "No alarms set"
        case .list:
            return "No timers running"
        case .start:
            return ""
        }
    }

    @ViewBuilder private var figure: some View {
        switch tray {
        case .start(.timer(let seconds, _)):
            Hero(text: ClockFormat.clock(seconds))
        case .start(.alarm(let date, _)):
            Hero(text: timeOfDay(date))
        case .stopwatch(let running?, _):
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                Hero(text: ClockFormat.stopwatch(running.elapsed(at: context.date)))
            }
        case .stopwatch(nil, _):
            Hero(text: "0:00.0")
        case .list(.alarm, _):
            Prompt(text: "Add a time, like “alarm 7:30”")
        case .list(.stopwatch, _), .list, .start:
            Prompt(text: "Add a length, like “timer 5m”")
        }
    }

    private struct Hero: View {
        let text: String
        var body: some View {
            Text(text)
                .font(.system(size: 42, weight: .semibold).monospacedDigit())
                .tracking(-1.47)
                .foregroundStyle(Quiet.ink1)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
    }

    private struct Prompt: View {
        let text: String
        var body: some View {
            Text(text)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Quiet.ink3)
        }
    }
}
