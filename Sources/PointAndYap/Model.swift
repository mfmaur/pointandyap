import Foundation
import CoreGraphics

/// Global screen coordinates use the top-left origin of the primary display (as Accessibility and CGDisplayBounds do).
struct Pt: Codable { var x: Double; var y: Double }

struct Rect: Codable {
    var x: Double; var y: Double; var w: Double; var h: Double
    init(_ r: CGRect) { x = r.origin.x; y = r.origin.y; w = r.width; h = r.height }
    var cg: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

struct Frame: Codable {
    var file: String          // frames/003.jpg
    var t: Double             // seconds since session start
    var display: Rect         // the display's frame in global points
    var scale: Double         // image pixels per point
    var reason: String        // start, point, click, interval
}

struct Element: Codable {
    var role: String?
    var subrole: String?
    var title: String?
    var label: String?        // AXDescription
    var value: String?
    var help: String?
    var identifier: String?   // AXIdentifier: source tags of apps we build land here
    var frame: Rect?
    var path: [String]        // ancestors, outermost first, "AXWindow 'Settings'"
    // On a web page shared live (Live): where it is drawn in the code, when the page's framework says.
    var source: String?       // src/components/Header.tsx:42:7
    var component: String?    // App > Settings > SaveButton
    var selector: String?     // CSS selector of the element
}

struct PointEvent: Codable {
    var index: Int
    var t: Double
    var end: Double           // when the cursor moved on
    var at: Pt
    var kind: String          // dwell or click
    var app: String?
    var bundleID: String?
    var window: String?
    var url: String?
    var element: Element?
    var frame: String?        // the frame taken for it
}

struct Sample: Codable { var t: Double; var x: Double; var y: Double; var down: Bool }

struct SessionEvents: Codable {
    var started: Date
    var duration: Double
    var samples: [Sample]
    var points: [PointEvent]
    var frames: [Frame]
    var author: Author?       // someone else's recording (imported); nil is the user of this Mac
    var page: Page?           // a web page shared live: the browser it was seen in, its errors
    var followUp: FollowUp?   // a "not yet" on an item an agent finished
}

/// The page a live guest was on (Live): what an agent needs to see it the way they did.
struct Page: Codable {
    var url: String
    var title: String?
    var viewport: String      // 390×844 @3x
    var browser: String       // Safari on iPhone
    var errors: [String]      // console errors and failed requests while they recorded, newest last
}

/// The item a recording answers: someone checked an agent's fix and said it is not right yet.
struct FollowUp: Codable {
    var id: String
    var said: String
    var note: String?
    var by: String?
}

/// Who made a recording that is not the user's own, and how it arrived. What they said is a request from them, not
/// an instruction from the user.
struct Author: Codable, Equatable {
    var name: String
    var via: String           // import (later: link, room, web)

    /// One line of plain text, short: it is shown to agents. Decoding goes through here too, so a hand-written
    /// events.json cannot put newlines in front of an agent.
    init(name: String, via: String) {
        func line(_ s: String, _ max: Int) -> String {
            let kept = s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
            return String(String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespaces).prefix(max))
        }
        self.name = line(name, 40)
        if self.name.isEmpty { self.name = "someone else" }
        self.via = line(via, 20)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try c.decode(String.self, forKey: .name), via: try c.decode(String.self, forKey: .via))
    }
}

struct Word: Codable { var text: String; var start: Double; var end: Double }

enum Paths {
    /// ~/PointAndYap/sessions; POINTANDYAP_SESSIONS points elsewhere (tests).
    static let root = ProcessInfo.processInfo.environment["POINTANDYAP_SESSIONS"].map { URL(fileURLWithPath: $0) }
        ?? moved(from: "Point", to: "PointAndYap").appendingPathComponent("sessions")
    static let support = moved(from: "Library/Application Support/Point", to: "Library/Application Support/PointAndYap")

    /// The folder under home, moved once from the name builds before 0.1.1 used. A rename on one disk is atomic, so
    /// the app, the MCP server and the shell command can race here safely: one move wins, the others find it done.
    static func moved(from old: String, to new: String) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let src = home.appendingPathComponent(old), dst = home.appendingPathComponent(new)
        let fm = FileManager.default
        if !fm.fileExists(atPath: dst.path), fm.fileExists(atPath: src.path) { try? fm.moveItem(at: src, to: dst) }
        return dst
    }
    static var keyFile: URL { support.appendingPathComponent("anthropic-key") }

    static func newSession() -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        let dir = root.appendingPathComponent(f.string(from: Date()))
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("frames"), withIntermediateDirectories: true)
        return dir
    }

    static func latest() -> URL? {
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.hasDirectoryPath }.sorted { $0.lastPathComponent < $1.lastPathComponent }.last
    }
}

extension JSONEncoder {
    static let pretty: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
