import XCTest
@testable import PointAndYap

/// A synthetic recording ("This button should be blue, not gray, and here, the date is wrong. It should say today.",
/// a rest on a Save button, a short pass over a group, a rest on a date label), in a temporary sessions folder.
final class PointAndYapTests: XCTestCase {
    static let root: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pointandyap-tests-\(UUID().uuidString)/sessions")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("POINTANDYAP_SESSIONS", dir.path, 1)   // read once by Paths.root
        return dir
    }()

    /// A processed copy of the fixture under its own id.
    func session(_ id: String) -> URL {
        let src = Bundle.module.url(forResource: "Fixtures/2026-10-17_120000", withExtension: nil)!
        let dst = Self.root.appendingPathComponent(id)
        try? FileManager.default.removeItem(at: dst)
        try! FileManager.default.copyItem(at: src, to: dst)
        let events = try! JSONDecoder.iso.decode(SessionEvents.self, from: Data(contentsOf: dst.appendingPathComponent("events.json")))
        let words = try! JSONDecoder().decode([Word].self, from: Data(contentsOf: dst.appendingPathComponent("transcript.json")))
        _ = Builder.build(dir: dst, events: events, words: words)
        return dst
    }

    /// The temporary folder is set before anything reads Paths.root, which is read once.
    override class func setUp() { _ = root }

    override func setUpWithError() throws {
        // Never run against a real sessions folder: every test stops here unless Paths.root is the temporary one.
        guard Paths.root.standardizedFileURL.path == Self.root.standardizedFileURL.path,
              Paths.root.path.hasPrefix(FileManager.default.temporaryDirectory.path) else {
            fatalError("PointAndYapTests: Paths.root is \(Paths.root.path), not the temporary folder; refusing to touch it")
        }
        for d in (try? FileManager.default.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: d)
        }
    }

    func testSentencesSplitAtPunctuationAndPauses() {
        let w = [Word(text: "This", start: 0, end: 0.2), Word(text: "works.", start: 0.2, end: 0.5),
                 Word(text: "Next", start: 0.6, end: 0.8), Word(text: "one", start: 2.0, end: 2.2)]
        XCTAssertEqual(Builder.sentences(w).map { $0.words.count }, [2, 1, 1])
    }

    func testTimelineMarksWhereTheCursorRested() throws {
        let dir = session("2026-10-17_120001")
        let md = try String(contentsOf: dir.appendingPathComponent("session.md"), encoding: .utf8)
        XCTAssertTrue(md.contains("This [1] button"), md)
        XCTAssertTrue(md.contains("here, [3] the date"), md)
        XCTAssertTrue(md.contains("AXButton \"Save\""))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("crops/03.jpg").path))
    }

    func testOneRecordingIsOneItemWithItsPointsButNotCursorTravel() {
        let dir = session("2026-10-17_120002")
        let items = Items.items(in: dir, state: nil).items
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items[0].body.contains("[1] dwell"))
        XCTAssertTrue(items[0].body.contains("[3] dwell"))
        XCTAssertFalse(items[0].body.contains("[2] dwell"), "a 0.3 s pass is cursor travel")
        XCTAssertEqual(items[0].crops.count, 2)
    }

    func testTwoAgentsNeverGetTheSameItem() {
        _ = session("2026-10-17_120003")
        _ = session("2026-10-17_120004")
        let a = Items.openItems(limit: 1, take: true, agent: "a")
        let b = Items.openItems(limit: 5, take: true, agent: "b")
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(b.count, 1)
        XCTAssertNotEqual(a[0].id, b[0].id)
        XCTAssertTrue(Items.openItems(limit: 5, take: true, agent: "c").isEmpty)
    }

    func testDoneStaysDoneAndReleasedComesBack() {
        _ = session("2026-10-17_120005")
        let id = Items.openItems(limit: 1, take: true, agent: "a")[0].id
        XCTAssertEqual(Items.set([id], status: "open", agent: "a", note: "needs the user").changed, [id])
        let again = Items.openItems(limit: 1, take: true, agent: "b")
        XCTAssertEqual(again.first?.id, id)
        XCTAssertEqual(again.first?.note, "needs the user")
        XCTAssertEqual(Items.set([id], status: "done", agent: "b", note: "fixed").changed, [id])
        XCTAssertTrue(Items.openItems(limit: 5, take: true, agent: "c").isEmpty)
        XCTAssertFalse(Items.set([id], status: "in_progress", agent: "c", note: nil).missing.isEmpty, "a done item cannot be started")
    }

    func testAnAbandonedItemReturnsAfterTheLease() throws {
        let dir = session("2026-10-17_120006")
        var st = ItemState(source: "session")
        st.items["1"] = .init(status: "in_progress", by: "a", at: Date().addingTimeInterval(-Items.lease - 60), note: nil)
        Items.writeState(st, dir)
        XCTAssertEqual(Items.items(in: dir, state: Items.readState(dir)).items.first?.status, "open")
    }

    func testIdsOutsideTheSessionsFolderAreRefused() {
        XCTAssertEqual(Items.set(["../etc#1", "nope#1"], status: "done", agent: "x", note: nil).changed, [])
        XCTAssertNil(MCPServer.dir("../etc"))
    }

    func testMCPListsAndHandsOutItems() {
        _ = session("2026-10-17_120007")
        let tools = MCPServer.tools.compactMap { $0["name"] as? String }
        for t in ["get_open_items", "mark_done", "release_items", "start_items", "list_items", "get_session"] {
            XCTAssertTrue(tools.contains(t), t)
        }
        let r = MCPServer.call("get_open_items", ["images": false])
        let text = (r["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? ""
        XCTAssertTrue(text.contains("2026-10-17_120007#1"), text)
        XCTAssertTrue(text.contains("mark_done"))
        let done = MCPServer.call("mark_done", ["ids": ["2026-10-17_120007#1"], "note": "ok"])
        XCTAssertNil(done["isError"])
    }

    func testOnlyOurOldAgentEntriesAreReplaced() {
        XCTAssertTrue(AgentInstall.isOurOld(["command": "/Applications/Point.app/Contents/MacOS/Point", "args": ["--mcp"]]))
        XCTAssertFalse(AgentInstall.isOurOld(["command": "/usr/local/bin/point"]), "someone else's point server")
        XCTAssertFalse(AgentInstall.isOurOld(nil))
    }

    func testTheOldCodexTableGoesAndOthersStay() {
        let toml = """
        [mcp_servers.other]
        command = "x"

        [mcp_servers.point]
        command = "/Applications/Point.app/Contents/MacOS/Point"
        args = ["--mcp"]

        [mcp_servers.point.env]
        A = "1"

        [profile]
        name = "y"
        """
        let out = AgentInstall.removingTable("mcp_servers.point", from: toml) { $0.contains(AgentInstall.oldApp) }
        XCTAssertFalse(out.contains("mcp_servers.point"))
        XCTAssertTrue(out.contains("[mcp_servers.other]") && out.contains("[profile]"))
        let foreign = toml.replacingOccurrences(of: "/Applications/Point.app/Contents/MacOS/Point", with: "/opt/point")
        XCTAssertEqual(AgentInstall.removingTable("mcp_servers.point", from: foreign) { $0.contains(AgentInstall.oldApp) }, foreign)
    }
}
