import AppKit
import LauncherCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var panel: PanelController?
    private(set) var hotKey: HotKey?
    let indexer = Indexer()
    let model = SearchModel()
    let clocks = Clocks()
    private let usageFile = UsageFile()
    private let capsule = CapsuleController()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var settingsWindow: NSWindow?
    /// True while ⌘Space closes the panel, so the query outlives the close and comes back selected.
    private var keepsQuery = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Info.plist sets LSUIElement; this covers `swift run`, which has no Info.plist.
        NSApp.setActivationPolicy(.accessory)
        model.usage = usageFile.load()
        noteActivations()

        indexer.onChange = { [weak self] index in
            guard let self else { return }
            let first = model.index.scan.apps.isEmpty
            model.index = index
            if first { panel?.prewarm() }
        }
        indexer.start()

        let panel = PanelController(content: SearchView(model: model))
        self.panel = panel
        panel.willShow = { [weak self] in
            guard let self else { return }
            indexer.checkIfStale()
            model.refresh()
            model.notePointer()
        }
        panel.didHide = { [weak self] in
            guard let self, !keepsQuery else { return }
            model.query = ""
        }
        panel.keyHandler = { [weak self] in self?.handleKey($0) ?? false }
        panel.composingChanged = { [weak self] in self?.model.isComposing = $0 }
        model.onActivate = { [weak self] in self?.perform($0) }
        model.clocks = clocks
        // Keep a clock tray that's on screen in step when something starts, stops or goes off.
        clocks.onChange = { [weak self] in
            guard let self, case .clock = model.tray else { return }
            model.refresh()
        }
        model.onContentChange = { [weak panel] in panel?.contentChanged() }
        hotKey = HotKey { [weak self] in self?.togglePanel() }
        #if DEBUG
        DebugSnapshot.runIfAsked(self)
        DebugBench.runIfAsked(self)
        DebugIdle.start()
        #endif
    }

    func togglePanel() {
        guard panel?.isShown == true else { return showPanel() }
        // Every other way of closing clears the field; ⌘Space keeps it for the next open.
        keepsQuery = true
        panel?.hide()
        keepsQuery = false
    }

    func showPanel() {
        panel?.show()
        // After the panel is key, so the field can take focus.
        DispatchQueue.main.async { self.model.focusRequest += 1 }
    }

    /// The keys a text field would otherwise swallow. Not called while an input method composes.
    private func handleKey(_ event: NSEvent) -> Bool {
        let commandOnly = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
        switch PanelKey.decide(keyCode: Int(event.keyCode), commandOnly: commandOnly,
                               characters: event.charactersIgnoringModifiers, queryIsEmpty: model.query.isEmpty) {
        case .moveDown: model.move(1)
        case .moveUp: model.move(-1)
        case .acceptCompletion: model.acceptGhost()
        case .clear: model.query = ""
        case .close: panel?.hide()
        case .activate(let reveal): model.activateSelection(reveal: reveal)
        case .copy: return model.copyResult()
        case .openRecent(let n): return model.openRecent(n)
        case .pass: return false
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        usageFile.flush()
    }

    /// SwiftUI's `Settings` scene and `openSettings` do nothing from a `MenuBarExtra` in an app with
    /// no Dock icon, so Spotty keeps its own settings window.
    func showSettings() {
        let window = settingsWindow ?? {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(delegate: self)))
            window.title = "Spotty Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            // Comes to the Space you are on rather than sending you to the one it was opened on.
            window.collectionBehavior = [.moveToActiveSpace]
            window.center()
            // Closing lets it go, so Spotty never keeps an ordinary window parked on some Space.
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.settingsWindow = nil }
            }
            settingsWindow = window
            return window
        }()
        // An ordinary window, unlike the panel, so it should come to the front. macOS may decline
        // the activation, so order the window in front regardless.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// Settings' "Reset learned ranking".
    func resetLearning() {
        model.usage = UsageStore()
        usageFile.saveNow(model.usage)
        model.refresh()
    }

    private func perform(_ activation: Activation) {
        guard let panel else { return }
        let frame = panel.panel.frame
        let say = { [capsule] (text: String) in capsule.show(text, centeredAt: frame.midX, top: frame.maxY) }
        switch activation {
        case .copy(let display, let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)  // "1467.87", never "1,467.87"
            panel.hide()
            say("Copied \(display)")
        case .startClock(let command):
            panel.hide()
            guard let item = clocks.start(command) else { return }
            switch item.kind {
            case .timer: say("Timer set for \(ClockFormat.spoken(item.duration ?? 0))")
            case .alarm: say("Alarm set for \(item.end.map(timeOfDay) ?? "")")
            case .stopwatch: say("Stopwatch started")
            }
        case .stopClock(let item):
            panel.hide()
            guard clocks.stop(item.id) != nil else { return }
            switch item.kind {
            case .stopwatch: say("Stopwatch stopped at \(ClockFormat.stopwatch(item.elapsed(at: .now)))")
            case .timer: say("Cancelled \(item.title)")
            case .alarm: say("Cancelled alarm for \(item.end.map(timeOfDay) ?? "")")
            }
        case .launch(let app, _, reveal: true):
            panel.hide()
            NSWorkspace.shared.activateFileViewerSelecting([app.url])
        case .launch(let app, let query, reveal: false):
            // An empty query (a Recent row) only updates frecency and recents, never a pick.
            model.usage.recordLaunch(of: app.id, query: QueryKeys(query), at: .now)
            usageFile.changed(model.usage, .soon)  // carries a learned pick
            // Nothing is shown after opening an app: the app itself is the confirmation.
            panel.hide()
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: app.url, configuration: config) { _, error in
                guard error != nil else { return }
                // Moved or deleted since the last scan.
                Task { @MainActor in self.indexer.rescan() }
            }
        }
    }

    /// Apps brought to the front some other way (Dock, ⌘Tab) count as recent too.
    private func noteActivations() {
        let center = NSWorkspace.shared.notificationCenter
        // Write anything pending before the Mac sleeps, logs out or switches user.
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.willPowerOffNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [usageFile] _ in
                usageFile.flush()
            })
        }
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                debugNote("activation \(id ?? "?")")
                guard let self, let id, id != Bundle.main.bundleIdentifier else { return }
                self.model.usage.noteUse(of: id, at: .now)
                self.usageFile.changed(self.model.usage, .eventually)  // Recent only
            }
        })
    }
}
