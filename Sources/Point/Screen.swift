import AppKit
import ScreenCaptureKit

/// Screenshots of the display under the cursor, as JPEG files.
enum Screen {
    /// The display containing a global top-left point.
    static func displayID(at p: CGPoint) -> CGDirectDisplayID {
        var id: CGDirectDisplayID = CGMainDisplayID()
        var count: UInt32 = 0
        CGGetDisplaysWithPoint(p, 1, &id, &count)
        return count > 0 ? id : CGMainDisplayID()
    }

    static func capture(at p: CGPoint, to url: URL) async -> (display: CGRect, scale: Double)? {
        let id = displayID(at: p)
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first else { return nil }
            let mode = CGDisplayCopyDisplayMode(display.displayID)
            let scale = mode.map { Double($0.pixelWidth) / Double($0.width) } ?? 2
            let mine = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.width = Int(Double(display.width) * scale)
            cfg.height = Int(Double(display.height) * scale)
            cfg.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            guard write(image, to: url) else { return nil }
            return (CGDisplayBounds(display.displayID), scale)
        } catch {
            NSLog("point: screenshot failed: \(error.localizedDescription)")
            return nil
        }
    }

    static func write(_ image: CGImage, to url: URL, quality: Double = 0.75) -> Bool {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) else { return false }
        return (try? data.write(to: url)) != nil
    }

    /// Asks for Screen Recording by touching the capture API once.
    static func askForAccess() {
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
    }
}
