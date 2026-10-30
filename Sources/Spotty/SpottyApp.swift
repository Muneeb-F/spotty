import SwiftUI

@main
struct SpottyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(delegate: delegate, clocks: delegate.clocks)
        } label: {
            MenuBarLabel(clocks: delegate.clocks)
        }
    }
}

/// The magnifying glass, or while a clock runs, its icon and figure ("4:59").
private struct MenuBarLabel: View {
    let clocks: Clocks

    var body: some View {
        if let text = clocks.menuBarText {
            Image(systemName: clocks.menuBarSymbol)
            Text(text).monospacedDigit()
        } else {
            Image(systemName: "magnifyingglass")
        }
    }
}

private struct MenuContent: View {
    let delegate: AppDelegate
    let clocks: Clocks

    var body: some View {
        Button("Open Spotty") { delegate.showPanel() }
        if delegate.hotKey?.isRegistered == false {
            Text("⌘Space is taken by another app")
        }
        if !clocks.board.isEmpty {
            Divider()
            ForEach(clocks.board.items) { item in
                Button("Stop \(item.title) · \(item.readout(at: clocks.now))") { clocks.stop(item.id) }
            }
        }
        Divider()
        Button("Settings…") { delegate.showSettings() }
            .keyboardShortcut(",")
        Button("Quit Spotty") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
