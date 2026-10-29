import AppKit
import WebKit

/// A live guest's screen, drawn again on this Mac: their page as it was (the bar sends its DOM, with form values,
/// scroll positions and the page's styles, no scripts), loaded from the dev server here at their window's size. No
/// screen sharing is asked of them, and it works the same on a phone.
@MainActor
enum Snapshot {
    static func render(html: String, base: URL, width: Double, height: Double, scrollX: Double, scrollY: Double) async -> CGImage? {
        let w = min(max(width, 240), 2560), h = min(max(height, 240), 2560)
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = false   // the page's own scripts never run here
        cfg.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: w, height: h), configuration: cfg)
        let win = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: w, height: h), styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.sharingType = .none
        win.contentView = web
        win.orderBack(nil)
        defer { win.orderOut(nil); win.contentView = nil }

        let loaded = Loaded()
        web.navigationDelegate = loaded
        web.loadHTMLString(html, baseURL: base)
        await loaded.wait(seconds: 10)
        // Scripts the app injects still run with the page's own off.
        let js = """
        document.documentElement.style.scrollBehavior = 'auto';
        for (const e of document.querySelectorAll('[data-pay-scroll]')) {
          const [x, y] = e.getAttribute('data-pay-scroll').split(',').map(Number); e.scrollLeft = x; e.scrollTop = y;
        }
        window.scrollTo(\(scrollX), \(scrollY)); true
        """
        _ = try? await web.evaluateJavaScript(js)
        try? await Task.sleep(nanoseconds: 350_000_000)   // fonts and images that came late
        let conf = WKSnapshotConfiguration()
        conf.afterScreenUpdates = true
        guard let img = try? await web.takeSnapshot(configuration: conf) else { return nil }
        return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private final class Loaded: NSObject, WKNavigationDelegate {
        private var k: CheckedContinuation<Void, Never>?
        private var done = false

        func wait(seconds: Double) async {
            if done { return }
            await withCheckedContinuation { c in
                k = c
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.finish() }
            }
        }

        private func finish() {
            done = true
            k?.resume()
            k = nil
        }

        func webView(_ w: WKWebView, didFinish n: WKNavigation!) { finish() }
        func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { finish() }
        func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { finish() }
    }
}
