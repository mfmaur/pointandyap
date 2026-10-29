import AppKit
import SwiftUI

@main
struct Main {
    static func main() {
        let args = CommandLine.arguments
        // The queue from a shell, for agents without the MCP:
        //   PointAndYap --items            open and in-progress items
        //   PointAndYap --done <id>... [--note "what changed"]
        if args.contains("--items") || args.contains("--done") { QueueCLI.run(args); return }
        // Review links: --share [<session>] [--relay <url>], --pull, --links, --revoke <id>, --accept <item id>...
        if ["--share", "--invite", "--pull", "--links", "--revoke", "--accept", "--join", "--leave", "--send"].contains(where: args.contains) {
            LinksCLI.run(args); return
        }
        // Live review of the app on a localhost port: PointAndYap --live <port> [--trust] [--private] [--open]
        if args.contains("--live") { LiveCLI.run(args); return }
        // Waits for an open item and takes it (live fixes from a shell): PointAndYap --wait [seconds]
        if args.contains("--wait") { QueueCLI.wait(args); return }
        // Local MCP server for coding agents: PointAndYap --mcp
        if args.contains("--mcp") { MCPServer.run(); return }
        // Headless: PointAndYap --process <session dir>
        if let i = args.firstIndex(of: "--process"), i + 1 < args.count {
            let dir = URL(fileURLWithPath: args[i + 1])
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                let text = await Process.run(dir: dir) { print("pointandyap: \($0)") }
                print(text)
                done.signal()
            }
            done.wait()
            return
        }
        // Someone else's recording into the queue: PointAndYap --import <folder or .zip> [--author name]
        if let i = args.firstIndex(of: "--import"), i + 1 < args.count {
            let src = URL(fileURLWithPath: args[i + 1])
            let author = args.firstIndex(of: "--author").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            let done = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var failed = false
            Task.detached {
                do {
                    let dir = try await Import.run(src, author: author)
                    let items = Items.items(in: dir, state: nil).items
                    print("Imported \(dir.lastPathComponent)\(items.first.map { " from \($0.author?.name ?? "?"): \"\($0.title)…\"" } ?? " (no speech)")\(items.count > 1 ? ", \(items.count) requests" : "")")
                } catch {
                    print("Not imported: \(error)")
                    failed = true
                }
                done.signal()
            }
            done.wait()
            if failed { exit(1) }
            return
        }
        // Offscreen design check: PointAndYap --render-ui <dir>
        if let i = args.firstIndex(of: "--render-ui"), i + 1 < args.count {
            MainActor.assumeIsolated { RenderUI.run(to: URL(fileURLWithPath: args[i + 1])) }
            return
        }
        // Settings of builds before 0.1.1 (bundle id com.marcmaurer.point), carried over once.
        let d = UserDefaults.standard
        if !d.bool(forKey: "migratedSettings"), let old = d.persistentDomain(forName: "com.marcmaurer.point") {
            for (k, v) in old where d.object(forKey: k) == nil { d.set(v, forKey: k) }
        }
        d.set(true, forKey: "migratedSettings")
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let state = AppState()
    private var window: NSWindow!
    private var pill: NSPanel!
    private var previousApp: NSRunningApplication?
    private var doubleControl: DoubleControl?

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.mainMenu = makeMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 590),
                          styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .white
        window.appearance = NSAppearance(named: .aqua)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: MainView(state: state))
        window.center()
        window.setFrameAutosaveName("PointMain")

        pill = NSPanel(contentRect: NSRect(x: 0, y: 0, width: PillView.width, height: 40), styleMask: [.borderless, .nonactivatingPanel],
                       backing: .buffered, defer: false)
        pill.level = .statusBar
        pill.isFloatingPanel = true
        pill.hasShadow = true
        pill.backgroundColor = .clear
        pill.isOpaque = false
        pill.isMovableByWindowBackground = true
        pill.sharingType = .none                  // never in a screenshot
        pill.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        pill.appearance = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: PillView(state: state))
        host.frame = NSRect(x: 0, y: 0, width: PillView.width, height: 40)
        pill.contentView = host

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { if let app, app != .current { self?.previousApp = app } }
        }
        state.ownUI = { [weak self] in self?.pillRect() }
        state.onRecordingChanged = { [weak self] on in self?.recording(on) }
        // Agent configs are only touched after a yes: the first launch asks, later launches follow the switch.
        if AgentInstall.installed {
            if AgentInstall.needsAsking() { state.askAgents = AgentInstall.status().map(\.name) }
            else { DispatchQueue.global(qos: .utility).async { AgentInstall.run() } }
        }
        // Agents mark items done from their own processes: read the states again while the window shows.
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if let self, self.window.isVisible, self.state.phase == .idle { self.state.loadSessions() } }
        }
        // Review links: what guests sent, every 30 s (nothing goes online without a link).
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if self?.state.phase == .idle { self?.state.pullLinks(); Task { await Join.retry() } } }
        }
        state.refreshAccess()
        doubleControl = DoubleControl(fire: { [weak self] in if Prefs.doubleControl { self?.state.toggle() } },
                                      escape: { [weak self] in if Prefs.escCancels { self?.state.cancel() } })
        state.loadSessions()
        Updater.shared.start(state: state)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// pointandyap://join?link=<an invite>: asks in the window before anything is sent anywhere.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "pointandyap" && url.host == "join" {
            // A link that launches the app arrives before applicationDidFinishLaunching makes the window, which then shows itself.
            if case .recording = state.phase {} else { window?.makeKeyAndOrderFront(nil); NSApp.activate() }
            Task { await state.lookInvite(url.absoluteString) }
        }
    }

    /// A live link ends with the app (its tunnel is a child process).
    func applicationWillTerminate(_ note: Notification) { state.live?.stop() }

    func applicationDidBecomeActive(_ note: Notification) { state.refreshAccess(); state.loadSessions() }

    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if case .recording = state.phase { return false }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    private func recording(_ on: Bool) {
        if on {
            window.orderOut(nil)
            let screen = NSScreen.main ?? NSScreen.screens[0]
            let f = screen.visibleFrame
            pill.setFrameOrigin(NSPoint(x: f.midX - PillView.width / 2, y: f.maxY - 52))
            pill.orderFrontRegardless()
            // Hand the screen back to the app that was in front before Point and Yap.
            previousApp?.activate()
        } else {
            // Stay out of the way: the session is in the list and on the clipboard; the Dock icon opens the window.
            pill.orderOut(nil)
        }
    }

    /// The pill in global top-left coordinates, with a margin.
    private func pillRect() -> CGRect? {
        guard pill.isVisible else { return nil }
        let h = NSScreen.screens.first?.frame.height ?? 0
        let f = pill.frame.insetBy(dx: -12, dy: -12)
        return CGRect(x: f.minX, y: h - f.maxY, width: f.width, height: f.height)
    }

    @objc private func checkForUpdates() { Updater.shared.checkNow() }

    /// ⌘Q and the menu's Quit: the user's choice, so no reopen.
    @objc private func quitByUser() {
        Relaunch.cancel()
        NSApp.terminate(nil)
    }

    @objc private func openSettings() {
        state.showSettings = true
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        appMenu.addItem(updates)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide Point and Yap", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Point and Yap", action: #selector(quitByUser), keyEquivalent: "q")
        quit.target = self
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        let winItem = NSMenuItem(); main.addItem(winItem)
        let win = NSMenu(title: "Window")
        win.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        win.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        winItem.submenu = win
        return main
    }
}
