import AppKit
import SwiftUI

@main
struct Main {
    static func main() {
        let args = CommandLine.arguments
        // Headless: Point --process <session dir> [--no-claude]
        if let i = args.firstIndex(of: "--process"), i + 1 < args.count {
            let dir = URL(fileURLWithPath: args[i + 1])
            let useClaude = !args.contains("--no-claude")
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                let text = await Process.run(dir: dir, useClaude: useClaude) { print("point: \($0)") }
                print(text)
                done.signal()
            }
            done.wait()
            return
        }
        // Offscreen design check: Point --render-ui <dir>
        if let i = args.firstIndex(of: "--render-ui"), i + 1 < args.count {
            MainActor.assumeIsolated { RenderUI.run(to: URL(fileURLWithPath: args[i + 1])) }
            return
        }
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
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
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

        pill = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 170, height: 40), styleMask: [.borderless, .nonactivatingPanel],
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
        host.frame = NSRect(x: 0, y: 0, width: 170, height: 40)
        pill.contentView = host

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { if let app, app != .current { self?.previousApp = app } }
        }
        state.ownUI = { [weak self] in self?.pillRect() }
        state.onRecordingChanged = { [weak self] on in self?.recording(on) }
        state.refreshAccess()
        doubleControl = DoubleControl { [weak self] in self?.state.toggle() }
        state.loadSessions()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationDidBecomeActive(_ note: Notification) { state.refreshAccess() }

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
            pill.setFrameOrigin(NSPoint(x: f.midX - 85, y: f.maxY - 52))
            pill.orderFrontRegardless()
            // Hand the screen back to the app that was in front before Point.
            previousApp?.activate()
        } else {
            pill.orderOut(nil)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// The pill in global top-left coordinates, with a margin.
    private func pillRect() -> CGRect? {
        guard pill.isVisible else { return nil }
        let h = NSScreen.screens.first?.frame.height ?? 0
        let f = pill.frame.insetBy(dx: -12, dy: -12)
        return CGRect(x: f.minX, y: h - f.maxY, width: f.width, height: f.height)
    }

    private func makeMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Hide Point", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Point", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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
