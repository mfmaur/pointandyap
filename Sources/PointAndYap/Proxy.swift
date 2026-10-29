import CryptoKit
import Foundation
import Network

/// One HTTP/1.1 head, a request's or a response's.
struct HTTPHead {
    var line: String                    // "GET /x HTTP/1.1" or "HTTP/1.1 200 OK"
    var headers: [(String, String)]

    func get(_ name: String) -> String? { headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1 }
    func all(_ name: String) -> [String] { headers.filter { $0.0.caseInsensitiveCompare(name) == .orderedSame }.map(\.1) }

    mutating func set(_ name: String, _ value: String?) {
        headers.removeAll { $0.0.caseInsensitiveCompare(name) == .orderedSame }
        if let value { headers.append((name, value)) }
    }

    var parts: [String] { line.split(separator: " ", maxSplits: 2).map(String.init) }
    var method: String { parts.first ?? "" }
    var target: String { parts.count > 1 ? parts[1] : "/" }
    var path: String { String(target.split(separator: "?", maxSplits: 1).first ?? "/") }
    var status: Int { parts.count > 1 ? Int(parts[1]) ?? 0 : 0 }

    var data: Data { Data((([line] + headers.map { "\($0.0): \($0.1)" }).joined(separator: "\r\n") + "\r\n\r\n").utf8) }

    /// The head at the start of `d` and how many bytes it took, or nil while it is incomplete.
    static func parse(_ d: Data) -> (HTTPHead, Int)? {
        guard let end = d.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let text = String(decoding: d[d.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        let first = lines.removeFirst()
        let headers = lines.compactMap { l -> (String, String)? in
            guard let c = l.firstIndex(of: ":") else { return nil }
            return (String(l[..<c]).trimmingCharacters(in: .whitespaces), String(l[l.index(after: c)...]).trimmingCharacters(in: .whitespaces))
        }
        return (HTTPHead(line: first, headers: headers), end.upperBound - d.startIndex)
    }

    func cookie(_ name: String) -> String? {
        for c in all("Cookie").flatMap({ $0.split(separator: ";") }) {
            let kv = c.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == name { return String(kv[1]) }
        }
        return nil
    }
}

/// A TCP connection with async reads and writes, and what was read ahead of the caller.
final class Wire: @unchecked Sendable {
    let c: NWConnection
    var pending = Data()
    /// Its own serial queue: one connection's events must arrive in order.
    let queue = DispatchQueue(label: "pointandyap.live.wire")
    init(_ c: NWConnection) { self.c = c }

    func open() async throws {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            let once = Once()
            c.stateUpdateHandler = { [c] st in
                switch st {
                case .ready: once.run { k.resume() }
                case .waiting(let e), .failed(let e): once.run { k.resume(throwing: e) }; c.cancel()
                case .cancelled: once.run { k.resume(throwing: NWError.posix(.ECANCELED)) }
                default: break
                }
            }
            c.start(queue: queue)
        }
    }

    /// The next bytes; nil once the other side has finished.
    func read() async -> Data? {
        if !pending.isEmpty { defer { pending = Data() }; return pending }
        return await withCheckedContinuation { k in
            c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, done, err in
                if let data, !data.isEmpty { k.resume(returning: data) }
                else if done || err != nil { if let err { Proxy.debug("read: \(err)") }; k.resume(returning: nil) }
                else { k.resume(returning: Data()) }
            }
        }
    }

    /// A head (at most 64 KB), keeping what follows it for the next read.
    func readHead() async -> HTTPHead? {
        var buf = Data()
        while let more = await read() {
            buf += more
            // A read can bring the head and much of the body at once.
            if let (h, n) = HTTPHead.parse(buf) { pending = Data(buf.dropFirst(n)); return h }
            if buf.count > 64 << 10 { return nil }
        }
        return nil
    }

    /// Exactly n bytes, or fewer if the connection ends.
    func read(exactly n: Int) async -> Data {
        var out = Data()
        while out.count < n, let more = await read() { out += more }
        if out.count > n { pending = Data(out.dropFirst(n)) + pending; out = Data(out.prefix(n)) }
        return out
    }

    @discardableResult
    func write(_ d: Data) async -> Bool {
        // Not complete: on TCP a complete send also ends the stream, and a server may hang up before it answers.
        await withCheckedContinuation { k in c.send(content: d, isComplete: false, completion: .contentProcessed { k.resume(returning: $0 == nil) }) }
    }

    func close() {
        c.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [c] _ in c.cancel() })
    }
}

/// Runs a body once (continuations must be resumed exactly once).
final class Once: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func run(_ f: () -> Void) {
        lock.lock(); let first = !done; done = true; lock.unlock()
        if first { f() }
    }
}

/// A local reverse proxy in front of a dev server (`localhost:<upstream>`): it lets in only browsers that came through a
/// live link (a cookie set by `/__pay/k/<token>`), puts the review bar into every HTML page, and passes everything else
/// through untouched, WebSockets included, so the dev server's hot reload reaches guests too.
final class Proxy: @unchecked Sendable {
    let upstream: Int
    /// The browser a request comes from may enter: the role for the token in its cookie.
    var role: (String) -> String? = { _ in nil }
    /// Requests under /__pay/ that are not the proxy's own: the live session answers them.
    var api: (HTTPHead, Wire, String) async -> Void = { _, w, _ in await Proxy.respond(w, 404, "text/plain", Data("not found".utf8)) }
    private var listener: NWListener?
    private(set) var port = 0

    init(upstream: Int) { self.upstream = upstream }

    /// Listens on 127.0.0.1 only (the tunnel reaches it from this Mac). Returns the port.
    func start(port: Int = 0) throws -> Int {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!)
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { st in if case .ready = st { ready.signal() } else if case .failed = st { ready.signal() } }
        l.newConnectionHandler = { [weak self] c in
            let w = Wire(c)
            c.start(queue: w.queue)
            Task { await self?.serve(w) }
        }
        l.start(queue: DispatchQueue(label: "pointandyap.live.listener"))
        _ = ready.wait(timeout: .now() + 5)
        guard let p = l.port?.rawValue, p != 0 else { throw Links.Failure.refused("could not listen") }
        listener = l
        self.port = Int(p)
        return Int(p)
    }

    func stop() { listener?.cancel(); listener = nil }

    static let cookie = "__pay"
    static let debugging = ProcessInfo.processInfo.environment["POINTANDYAP_LIVE_DEBUG"] != nil
    static func debug(_ s: @autoclosure () -> String) { if debugging { FileHandle.standardError.write(Data("proxy: \(s())\n".utf8)) } }

    func serve(_ w: Wire) async {
        guard let head = await w.readHead() else { w.close(); return }
        let path = head.path
        if path.hasPrefix("/__pay/k/") {
            // The link itself: remembered in a cookie, then on to the app.
            let token = String(path.dropFirst("/__pay/k/".count))
            guard role(token) != nil else { return await Self.gone(w) }
            let secure = head.get("X-Forwarded-Proto") == "https" ? "; Secure" : ""
            var h = HTTPHead(line: "HTTP/1.1 302 Found", headers: [("Location", "/"), ("Cache-Control", "no-store"), ("Content-Length", "0"), ("Connection", "close")])
            h.headers.append(("Set-Cookie", "\(Self.cookie)=\(token); Path=/; HttpOnly; SameSite=Lax; Max-Age=86400\(secure)"))
            // Who this browser is, kept across reloads: what it sent, and what it may confirm, belongs to it.
            if head.cookie("\(Self.cookie)_g") == nil {
                h.headers.append(("Set-Cookie", "\(Self.cookie)_g=\(LiveSession.token()); Path=/; HttpOnly; SameSite=Lax; Max-Age=86400\(secure)"))
            }
            await w.write(h.data)
            return w.close()
        }
        if path == "/__pay/bar.js" {
            return await Self.respond(w, 200, "text/javascript; charset=utf-8", LiveAssets.bar, extra: [("Cache-Control", "no-cache")])
        }
        guard let token = head.cookie(Self.cookie), let who = role(token) else { return await Self.gone(w) }
        if path.hasPrefix("/__pay/") { return await api(head, w, who) }
        await forward(head, w)
    }

    // MARK: Passing through

    func forward(_ req: HTTPHead, _ client: Wire) async {
        var head = req
        let origin = "http://localhost:\(upstream)"
        let upgrade = head.get("Upgrade") != nil
        // As if the browser were on this Mac: dev servers check Host and Origin (Vite's allowedHosts, Next's dev origins).
        head.set("Host", "localhost:\(upstream)")
        if head.get("Origin") != nil { head.set("Origin", origin) }
        if let r = head.get("Referer"), let u = URLComponents(string: r) {
            head.set("Referer", origin + u.percentEncodedPath + (u.percentEncodedQuery.map { "?\($0)" } ?? ""))
        }
        for h in ["X-Forwarded-Host", "X-Forwarded-Proto", "Cf-Visitor"] { head.set(h, nil) }
        let cookies = head.all("Cookie").flatMap { $0.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) } }
            .filter { !$0.hasPrefix("\(Self.cookie)=") && !$0.hasPrefix("\(Self.cookie)_") }
        head.set("Cookie", cookies.isEmpty ? nil : cookies.joined(separator: "; "))
        if !upgrade {
            head.set("Connection", "close")
            head.set("Accept-Encoding", "identity")   // the page is read to put the bar in
        }

        let up = Wire(NWConnection(host: "localhost", port: NWEndpoint.Port(rawValue: UInt16(upstream))!, using: .tcp))
        do { try await up.open() } catch { Self.debug("open \(req.target): \(error)"); return await Self.down(client, upstream) }
        defer { up.c.cancel() }
        await up.write(head.data)

        // The request body: by its length, or as it comes.
        let sending = Task {
            if let n = Int(head.get("Content-Length") ?? ""), n > 0 {
                var left = n
                while left > 0, let d = await client.read() { await up.write(Data(d.prefix(left))); left -= d.count }
            } else if head.get("Transfer-Encoding")?.lowercased().contains("chunked") == true {
                while let d = await client.read() { await up.write(d); if d.suffix(5) == Data("0\r\n\r\n".utf8) { break } }
            }
        }

        guard var res = await up.readHead() else { Self.debug("no answer for \(req.target) from \(String(describing: up.c.currentPath?.remoteEndpoint)) \(up.c.state)"); sending.cancel(); return await Self.down(client, upstream) }
        if res.status == 101 {
            // A WebSocket (hot reload): both ways, untouched, until either side closes.
            await sending.value
            await client.write(res.data)
            await Self.pipe(client, up)
            return
        }
        await sending.value
        rewrite(&res)
        let html = (res.get("Content-Type") ?? "").lowercased().contains("text/html") && req.method != "HEAD" && ![204, 304].contains(res.status)
        let chunked = res.get("Transfer-Encoding")?.lowercased().contains("chunked") == true
        let length = Int(res.get("Content-Length") ?? "")

        if html {
            var body = Data()
            if let length { body = await up.read(exactly: length) }
            else { while let d = await up.read(), body.count < 32 << 20 { body += d } }
            if chunked { body = Self.dechunk(body) }
            body = Self.inject(body)
            res.set("Transfer-Encoding", nil)
            res.set("Content-Length", String(body.count))
            // The bar is a script of this origin; a page that allows only hashed or nonced scripts would refuse it.
            res.set("Content-Security-Policy", nil)
            res.set("Content-Security-Policy-Report-Only", nil)
            res.set("Cache-Control", "no-store")
            res.set("ETag", nil)
            await client.write(res.data + body)
        } else {
            await client.write(res.data)
            var sent = 0
            while let d = await up.read() {
                await client.write(d)
                sent += d.count
                if let length, sent >= length { break }
                if length == nil, chunked, d.suffix(5) == Data("0\r\n\r\n".utf8) { break }
            }
        }
        client.close()
    }

    /// Response headers as seen from the link: redirects to this Mac's localhost become relative, cookies lose their
    /// domain, and every connection is closed after one answer.
    func rewrite(_ res: inout HTTPHead) {
        res.set("Connection", "close")
        res.set("Keep-Alive", nil)
        if let loc = res.get("Location") {
            for host in ["localhost", "127.0.0.1", "[::1]"] {
                let base = "http://\(host):\(upstream)"
                if loc.hasPrefix(base) { res.set("Location", String(loc.dropFirst(base.count)).isEmpty ? "/" : String(loc.dropFirst(base.count))) }
            }
        }
        let cookies = res.all("Set-Cookie").map { c in
            c.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.lowercased().hasPrefix("domain=") }.joined(separator: "; ")
        }
        res.set("Set-Cookie", nil)
        for c in cookies { res.headers.append(("Set-Cookie", c)) }
        res.set("Strict-Transport-Security", nil)
    }

    static let tag = Data("<script src=\"/__pay/bar.js\" data-pointandyap></script>".utf8)

    /// The bar's script, first thing in <head>, so it sees the page's errors from the start.
    static func inject(_ body: Data) -> Data {
        // Tags are ASCII: lowercase only A-Z, so byte offsets stay those of the page.
        let low = [UInt8](body.prefix(1 << 16)).map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }
        func after(_ open: String) -> Int? {
            let needle = [UInt8](open.utf8)
            guard low.count >= needle.count else { return nil }
            for i in 0...(low.count - needle.count) where Array(low[i..<(i + needle.count)]) == needle {
                let j = i + needle.count
                guard j < low.count, [62, 32, 9, 10, 13].contains(low[j]) else { continue }   // > or whitespace: not <header
                guard let close = low[j...].firstIndex(of: 62) else { return nil }
                return close + 1
            }
            return nil
        }
        guard let at = after("<head") ?? after("<html") else { return tag + body }
        return body.prefix(at) + tag + body.dropFirst(at)
    }

    /// The body of a chunked response, without the chunk framing.
    static func dechunk(_ d: Data) -> Data {
        var out = Data(), i = d.startIndex
        while i < d.endIndex {
            guard let nl = d[i...].range(of: Data("\r\n".utf8)) else { break }
            let sizeText = String(decoding: d[i..<nl.lowerBound], as: UTF8.self).split(separator: ";").first ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16), size > 0 else { break }
            let start = nl.upperBound, end = min(d.endIndex, start + size)
            out += d[start..<end]
            i = min(d.endIndex, end + 2)
        }
        return out
    }

    static func pipe(_ a: Wire, _ b: Wire) async {
        await withTaskGroup(of: Void.self) { g in
            g.addTask { while let d = await a.read() { if !(await b.write(d)) { break } }; b.close() }
            g.addTask { while let d = await b.read() { if !(await a.write(d)) { break } }; a.close() }
            await g.next()
            a.c.cancel(); b.c.cancel()
        }
    }

    // MARK: Answers

    static func respond(_ w: Wire, _ status: Int, _ type: String, _ body: Data, extra: [(String, String)] = []) async {
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 413: "Payload Too Large", 502: "Bad Gateway"][status] ?? "OK"
        let h = HTTPHead(line: "HTTP/1.1 \(status) \(reason)",
                         headers: [("Content-Type", type), ("Content-Length", String(body.count)), ("Connection", "close")] + extra)
        await w.write(h.data + body)
        w.close()
    }

    static func json(_ w: Wire, _ obj: Any, status: Int = 200) async {
        await respond(w, status, "application/json", (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8), extra: [("Cache-Control", "no-store")])
    }

    static func page(_ title: String, _ text: String, refresh: Bool = false) -> Data {
        Data("""
        <!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">\(refresh ? "<meta http-equiv=\"refresh\" content=\"3\">" : "")
        <title>\(title)</title><style>body{font:15px/1.5 -apple-system,system-ui,sans-serif;color:#1d1f23;max-width:30em;margin:18vh auto;padding:0 20px}
        h1{font-size:20px;font-weight:600}p{color:#5c5f66}</style><h1>\(title)</h1><p>\(text)</p>
        """.utf8)
    }

    static func gone(_ w: Wire) async {
        await respond(w, 403, "text/html; charset=utf-8",
                      page("This live link has ended", "Whoever sent it has stopped sharing, or the link is not complete. Ask them for a new one."))
    }

    static func down(_ w: Wire, _ port: Int) async {
        await respond(w, 502, "text/html; charset=utf-8",
                      page("The app is not running right now", "Nothing answers on their localhost:\(port) at the moment. This page tries again by itself.", refresh: true))
    }
}

// MARK: WebSocket (the room)

/// Just enough of RFC 6455 for the room: text messages, ping, close. Client frames are masked; ours are not.
enum WebSocket {
    static func accept(_ key: String) -> String {
        Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
    }

    static func handshake(_ req: HTTPHead, _ w: Wire) async -> Bool {
        guard req.get("Upgrade")?.lowercased() == "websocket", let key = req.get("Sec-WebSocket-Key") else { return false }
        let h = HTTPHead(line: "HTTP/1.1 101 Switching Protocols",
                         headers: [("Upgrade", "websocket"), ("Connection", "Upgrade"), ("Sec-WebSocket-Accept", accept(key))])
        return await w.write(h.data)
    }

    static func frame(_ text: String, opcode: UInt8 = 1) -> Data {
        let p = Data(text.utf8)
        var d = Data([0x80 | opcode])
        if p.count < 126 { d.append(UInt8(p.count)) }
        else if p.count < 65536 { d.append(126); d.append(UInt8(p.count >> 8)); d.append(UInt8(p.count & 0xFF)) }
        else { d.append(127); for s in stride(from: 56, through: 0, by: -8) { d.append(UInt8((UInt64(p.count) >> UInt64(s)) & 0xFF)) } }
        return d + p
    }

    /// Reads messages until the client goes; text messages to `onText`, at most 1 MB each.
    static func read(_ w: Wire, onText: (String) async -> Void) async {
        var buf = Data(), message = Data()
        func need(_ n: Int) async -> Bool {
            while buf.count < n { guard let more = await w.read() else { return false }; buf += more }
            return true
        }
        while await need(2) {
            let b0 = buf[buf.startIndex], b1 = buf[buf.startIndex + 1]
            var len = Int(b1 & 0x7F), off = 2
            if len == 126 { guard await need(4) else { return }; len = Int(buf[buf.startIndex + 2]) << 8 | Int(buf[buf.startIndex + 3]); off = 4 }
            else if len == 127 {
                guard await need(10) else { return }
                len = (2..<10).reduce(0) { $0 << 8 | Int(buf[buf.startIndex + $1]) }; off = 10
            }
            let masked = b1 & 0x80 != 0
            guard len < 1 << 20, await need(off + (masked ? 4 : 0) + len) else { return }
            let mask = masked ? Array(buf[(buf.startIndex + off)..<(buf.startIndex + off + 4)]) : [0, 0, 0, 0]
            let start = buf.startIndex + off + (masked ? 4 : 0)
            var payload = Data(buf[start..<(start + len)])
            if masked { for i in 0..<payload.count { payload[payload.startIndex + i] ^= mask[i % 4] } }
            buf = Data(buf[(start + len)...])
            switch b0 & 0x0F {
            case 0, 1:
                message += payload
                guard message.count < 1 << 20 else { return }
                if b0 & 0x80 != 0 { await onText(String(decoding: message, as: UTF8.self)); message = Data() }
            case 8: await w.write(Data([0x88, 0])); return
            case 9: var pong = Data([0x8A, UInt8(min(payload.count, 125))]); pong += payload.prefix(125); await w.write(pong)
            default: break
            }
        }
    }
}
