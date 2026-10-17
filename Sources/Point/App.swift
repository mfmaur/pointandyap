import AppKit
import Carbon.HIToolbox

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
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var recorder: Recorder?
    private var processing = false
    private var hotKey: EventHotKeyRef?
    private var started: Date?
    private var clockTimer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon("circle")
        rebuildMenu()
        registerHotKey()
        Task {
            _ = await AudioRecorder.askForAccess()
            Screen.askForAccess()
            if !AXProbe.trusted { AXProbe.askForTrust() }
        }
    }

    private func setIcon(_ symbol: String, color: NSColor? = nil, title: String = "") {
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Point")
        if let color, let img {
            let cfg = NSImage.SymbolConfiguration(paletteColors: [color])
            item.button?.image = img.withSymbolConfiguration(cfg)
        } else {
            img?.isTemplate = true
            item.button?.image = img
        }
        item.button?.title = title.isEmpty ? "" : " " + title
        item.button?.imagePosition = .imageLeading
    }

    private func rebuildMenu() {
        let m = NSMenu()
        let toggle = NSMenuItem(title: recorder == nil ? "Start recording" : "Stop recording",
                                action: #selector(toggle), keyEquivalent: "p")
        toggle.keyEquivalentModifierMask = [.control, .option]
        toggle.isEnabled = !processing
        m.addItem(toggle)
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Copy last instructions", action: #selector(copyLast), keyEquivalent: ""))
        m.addItem(NSMenuItem(title: "Open last session", action: #selector(openLast), keyEquivalent: ""))
        m.addItem(.separator())
        if !AXProbe.trusted {
            m.addItem(NSMenuItem(title: "Allow Accessibility…", action: #selector(askAX), keyEquivalent: ""))
        }
        m.addItem(NSMenuItem(title: "Quit Point", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for i in m.items where i.action != #selector(NSApplication.terminate(_:)) { i.target = self }
        item.menu = m
    }

    @objc func toggle() {
        if processing { return }
        if let r = recorder {
            recorder = nil
            processing = true
            clockTimer?.invalidate()
            setIcon("circle.lefthalf.filled", title: "…")
            rebuildMenu()
            Task {
                let dir = await r.stop()
                let text = await Process.run(dir: dir)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                NSSound(named: "Glass")?.play()
                processing = false
                setIcon("circle")
                rebuildMenu()
            }
        } else {
            let r = Recorder()
            do {
                try r.start()
            } catch {
                NSLog("point: could not start: \(error)")
                NSSound(named: "Basso")?.play()
                return
            }
            recorder = r
            started = Date()
            NSSound(named: "Tink")?.play()
            setIcon("record.circle.fill", color: .systemRed, title: "0:00")
            clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let s = self.started else { return }
                    let t = Int(Date().timeIntervalSince(s))
                    self.item.button?.title = String(format: " %d:%02d", t / 60, t % 60)
                }
            }
            rebuildMenu()
        }
    }

    @objc func copyLast() {
        guard let dir = Paths.latest() else { return }
        let file = ["instructions.md", "session.md"].map { dir.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        guard let file, let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func openLast() {
        if let dir = Paths.latest() { NSWorkspace.shared.open(dir) }
    }

    @objc func askAX() { AXProbe.askForTrust() }

    // ⌃⌥P through a Carbon hot key (no Accessibility needed).
    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.toggle() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x504F_4E54), id: 1)  // "PONT"
        RegisterEventHotKey(UInt32(kVK_ANSI_P), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
    }
}
