import AppKit
import SwiftUI

struct MainView: View {
    @ObservedObject var state: AppState
    @AppStorage("showNoSpeech") private var showNoSpeech = false

    var body: some View {
        if state.showSettings { SettingsView(state: state) }
        else if !state.askAgents.isEmpty { AgentsQuestion(state: state) }
        else { main }
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                AppTitle()
                Spacer()
                if state.live == nil && !state.pickingPort && !state.liveStarting {
                    Button { state.pickPort() } label: {
                        HStack(spacing: 5) { Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 11)); Text("Go live") }
                    }
                    .buttonStyle(SmallButton()).help("Share the app you're building on localhost: others point and talk on it")
                }
                Button { state.showSettings = true } label: { Image(systemName: "gearshape").font(.system(size: 13)) }
                    .buttonStyle(SmallButton()).help("Settings (⌘,)")
            }
            .padding(.bottom, 20)

            if !state.allowed { AccessRows(state: state).padding(.bottom, 16) }

            if let v = state.updateReady {
                HStack {
                    Circle().fill(Ink.gold).frame(width: 7, height: 7)
                    Text("Point and Yap \(v) is ready").font(.geist(13)).foregroundStyle(Ink.primary)
                    Spacer()
                    Button("Restart") { Updater.shared.restart() }.buttonStyle(SmallButton(dark: true))
                }
                .padding(.horizontal, 12).frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 10).fill(Ink.field))
                .padding(.bottom, 16)
            }

            if let j = state.invite {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(j.from ?? "Someone") wants your feedback").font(.geist(14, .medium)).foregroundStyle(Ink.primary)
                    Text("While you are joined, each recording goes to \(j.from ?? "them"): what you say, where you point and the screenshots there, encrypted to their Mac. It does not go to your own agents.")
                        .font(.geist(12)).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("Not now") { state.answerInvite(false) }.buttonStyle(SmallButton())
                        Button("Join") { state.answerInvite(true) }.buttonStyle(SmallButton(dark: true))
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 10).fill(Ink.field))
                .padding(.bottom, 16)
            } else if let j = state.joined {
                HStack {
                    Circle().fill(Ink.red).frame(width: 7, height: 7)
                    Text("Recordings go to \(j.to)").font(.geist(13)).foregroundStyle(Ink.primary)
                    Spacer()
                    Button("Stop") { state.leave() }.buttonStyle(SmallButton()).help("Keep recordings on this Mac again")
                }
                .padding(.horizontal, 12).frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 10).fill(Ink.field))
                .padding(.bottom, 16)
            }

            if state.live != nil || state.pickingPort || state.liveStarting { LiveCard(state: state).padding(.bottom, 16) }

            if state.showWelcome && state.allowed && state.phase == .idle {
                WelcomeCard(state: state).padding(.bottom, 16)
            }

            Button(action: state.start) {
                HStack(spacing: 8) {
                    if state.phase == .processing {
                        ProgressView().controlSize(.small).tint(.white)
                        Text("Writing instructions…")
                    } else {
                        Circle().fill(Ink.red).frame(width: 8, height: 8)
                        Text("Start recording")
                    }
                }
            }
            .buttonStyle(DarkButton())
            .disabled(state.phase != .idle || !state.allowed)
            .opacity(state.allowed ? 1 : 0.4)

            HStack(spacing: 4) {
                Text(state.showWelcome ? "Or press Control twice. Rest the cursor on what you mean." : "Or press Control twice.")
                    .font(.geist(12)).foregroundStyle(Ink.faint)
                if !state.showWelcome {
                    Button("How it works") { state.showWelcome = true }
                        .buttonStyle(.plain).font(.geist(12)).foregroundStyle(Ink.muted).underline()
                }
            }
            .padding(.top, 10)

            Text("Recent").font(.geist(11, .medium)).foregroundStyle(Ink.faint).tracking(0.6)
                .padding(.top, 26).padding(.bottom, 6)

            let shown = state.sessions.filter { showNoSpeech || !$0.noSpeech }
            if shown.isEmpty {
                Text("Nothing recorded yet").font(.geist(13)).foregroundStyle(Ink.muted).padding(.vertical, 10)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(shown) { row in
                            SessionRowView(row: row, state: state)
                            if row != shown.last { Divider().overlay(Ink.line) }
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 400, height: 590, alignment: .topLeading)
        .background(Color.white)
        .overlay(alignment: .bottom) {
            if let t = state.toast {
                Text(t).font(.geist(13)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Ink.primary))
                    .padding(.bottom, 18)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: state.toast)
    }
}

/// Icon, name and the one line under it.
struct AppTitle: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Point and Yap").font(.geist(15, .medium)).foregroundStyle(Ink.primary)
                Text("Show, don't type.").font(.geist(12)).foregroundStyle(Ink.muted)
            }
        }
    }
}

/// First run: nothing in an agent's config changes before this yes.
struct AgentsQuestion: View {
    @ObservedObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AppTitle().padding(.bottom, 28)
            Text("Connect your coding agents?").font(.geist(15, .medium)).foregroundStyle(Ink.primary)
            Text("They get a local MCP server and a skill to read your recordings. Each config is backed up first.")
                .font(.geist(12)).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6).padding(.bottom, 16)
            VStack(spacing: 0) {
                ForEach(state.askAgents, id: \.self) { name in
                    HStack { Text(name).font(.geist(13)).foregroundStyle(Ink.primary); Spacer() }.frame(height: 40)
                    if name != state.askAgents.last { Divider().overlay(Ink.line) }
                }
            }
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Ink.field))
            Button("Connect") { state.answerAgents(true) }.buttonStyle(DarkButton()).padding(.top, 20)
            Button("Skip") { state.answerAgents(false) }.buttonStyle(SmallButton()).frame(maxWidth: .infinity).padding(.top, 10)
            Text("You can change this in Settings.").font(.geist(12)).foregroundStyle(Ink.faint)
                .frame(maxWidth: .infinity).padding(.top, 10)
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 400, height: 590, alignment: .topLeading)
        .background(Color.white)
    }
}

struct AccessRows: View {
    @ObservedObject var state: AppState
    var body: some View {
        VStack(spacing: 0) {
            row("Microphone", ok: state.mic, action: state.askMic)
            Divider().overlay(Ink.line)
            row("Screen recording", ok: state.screen, action: state.askScreen)
            Divider().overlay(Ink.line)
            row("Accessibility", ok: state.ax, action: state.askAX)
        }
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Ink.field))
    }

    private func row(_ name: String, ok: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Text(name).font(.geist(13)).foregroundStyle(Ink.primary)
            Spacer()
            if ok {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.muted)
            } else {
                Button("Allow", action: action).buttonStyle(SmallButton())
            }
        }
        .frame(height: 40)
    }
}

struct SessionRowView: View {
    let row: SessionRow
    @ObservedObject var state: AppState
    @State private var hover = false
    @State private var open = false
    @State private var details: [(n: Int, said: String, status: String, by: String?, note: String?)] = []

    init(row: SessionRow, state: AppState, open: Bool = false) {
        self.row = row
        self.state = state
        _open = State(initialValue: open)
        _details = State(initialValue: open ? Self.details(row.dir) : [])
    }

    private static let time: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM, HH:mm"; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
            if open { detail }
        }
    }

    /// Everything that was said, request by request, and each fix's note in full.
    private var detail: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(details, id: \.n) { d in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if details.count > 1 { Text("\(d.n)").font(.geist(11, .medium)).foregroundStyle(Ink.faint) }
                        Text("“\(d.said)”").font(.geist(12)).foregroundStyle(Ink.primary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        Spacer(minLength: 0)
                        if details.count > 1 { StatusPill(status: d.status, by: d.by) }
                    }
                    if let note = d.note {
                        Text("\(d.by.map { "\(Live.agentName($0)): " } ?? "")\(note)").font(.geist(12)).foregroundStyle(Color(hex: 0x2F7A4B))
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
            }
            if details.isEmpty { Text("Nothing was said.").font(.geist(12)).foregroundStyle(Ink.muted) }
        }
        .padding(.leading, 18).padding(.bottom, 12)
    }

    private func load() { details = Self.details(row.dir) }

    private static func details(_ dir: URL) -> [(n: Int, said: String, status: String, by: String?, note: String?)] {
        Items.items(in: dir, state: Items.readState(dir)).items.map { ($0.n, Live.said($0, dir), $0.status, $0.by, $0.note) }
    }

    private var summary: some View {
        HStack(spacing: 10) {
            Button { open.toggle(); if open { load() } } label: {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Ink.faint)
                    .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 12, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(open ? "Hide" : "Show everything said, and the notes")
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.geist(13)).foregroundStyle(Ink.primary).lineLimit(1)
                Text("\(Self.time.string(from: row.date)) · \(row.duration) s\(row.requests > 1 ? " · \(row.requests) requests" : "")\(row.author.map { " · from \($0)" } ?? "")")
                    .font(.geist(11)).foregroundStyle(Ink.muted)
            }
            Spacer(minLength: 8)
            if !hover { StatusPill(status: row.status, by: row.by, note: row.note, confirmed: row.confirmed ? row.author : nil) }
            if hover {
                Button { state.open(row) } label: { Image(systemName: "folder") }.buttonStyle(SmallButton()).help("Open the folder")
                if row.author == nil {
                    Button { state.share(row) } label: { Image(systemName: "link") }.buttonStyle(SmallButton())
                        .help("Copy a review link: others point and talk on these screenshots, and it comes back here")
                }
                if row.status == "triage", row.by?.hasPrefix("sending to") == true {
                    // Waiting to go to whoever invited this Mac.
                } else if row.status == "triage" {
                    Button("Dismiss") { state.toggleDone(row) }.buttonStyle(SmallButton())
                    Button("Accept") { state.accept(row) }.buttonStyle(SmallButton(dark: true))
                        .help("Put it in the queue for your agents")
                } else if !row.status.isEmpty {
                    Button(row.status == "done" ? "Reopen" : "Done") { state.toggleDone(row) }.buttonStyle(SmallButton(dark: row.status != "done"))
                }
            }
        }
        .frame(height: 50)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { state.copy(row) }
        .onChange(of: row) { _, _ in if open { load() } }
        .help(row.note.map { "Note: \($0)" } ?? "Click to copy it for an agent")
    }
}

/// The floating pill while recording: red dot, time, what is pointed at (with undo), Area, Stop.
struct PillView: View {
    @ObservedObject var state: AppState
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Ink.red).frame(width: 8, height: 8)
                .opacity(pulse ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(elapsed(at: ctx.date)).font(.geistMono(13)).foregroundStyle(Ink.primary).frame(width: 36, alignment: .leading)
            }
            Divider().frame(height: 16)
            if state.areaOn {
                Text("Drag over the area").font(.geist(12)).foregroundStyle(Ink.red).fixedSize()
            } else if state.pointed > 0 {
                Text("\(state.pointed) pointed").font(.geist(12)).foregroundStyle(Ink.secondary).fixedSize()
                Button(action: state.takeBackLast) { Image(systemName: "arrow.uturn.backward").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(Ink.muted).help("Take back the last one (or ⌥-click any number)")
            } else {
                Text("Point and talk").font(.geist(12)).foregroundStyle(Ink.muted).fixedSize()
            }
            Spacer(minLength: 0)
            Button(action: state.toggleArea) {
                HStack(spacing: 4) {
                    Image(systemName: "rectangle.dashed").font(.system(size: 11, weight: .semibold))
                    Text("Area").font(.geist(12))
                }
                .padding(.horizontal, 8).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(state.areaOn ? Ink.red.opacity(0.12) : Color.clear))
                .foregroundStyle(state.areaOn ? Ink.red : Ink.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Drag a box over an area (or hold ⌥ and drag)")
            Button(action: state.cancel) { Text("esc").font(.geist(11)).foregroundStyle(Ink.faint) }
                .buttonStyle(.plain).help("Cancel and keep nothing")
            Button(action: state.stop) { Text("Stop  ") + Text("⌃⌃").font(.system(size: 11)).foregroundColor(Color(hex: 0x9A9DA4)) }.buttonStyle(SmallButton(dark: true))
        }
        .padding(.leading, 14).padding(.trailing, 6)
        .frame(width: PillView.width, height: 40)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.line, lineWidth: 1))
        .onAppear { pulse = true }
    }
    static let width = 360.0

    private func elapsed(at now: Date) -> String {
        guard case .recording(let s) = state.phase else { return "0:00" }
        let t = max(0, Int(now.timeIntervalSince(s)))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// "To fix" (gold), "In progress · claude-code" (grey) or "Done" (green).
struct StatusPill: View {
    let status: String
    let by: String?
    var note: String? = nil
    var confirmed: String? = nil   // who checked the fix
    var body: some View {
        switch status {
        case "done" where confirmed != nil: pill("\(confirmed!) confirmed", 0x2F7A4B, 0xF1FAF4, 0xCFE8D8)
        case "triage" where by?.hasPrefix("sending to") == true: pill("Sending…", 0x3A3C41, 0xF3F3F5, 0xE3E4E7)
        case "done" where by == "you" && note?.hasPrefix("Sent to ") == true: pill(note!, 0x2F7A4B, 0xF1FAF4, 0xCFE8D8)
        case "open": pill("To fix", 0x6B5414, 0xFFF7E0, 0xF3E3B5)
        case "in_progress": pill("In progress" + (by.map { " · \($0)" } ?? ""), 0x3A3C41, 0xF3F3F5, 0xE3E4E7)
        case "done": pill("Done", 0x2F7A4B, 0xF1FAF4, 0xCFE8D8)
        case "triage": pill("To accept", 0x1F4E8C, 0xEEF4FD, 0xC9DBF5)
        default: EmptyView()
        }
    }

    private func pill(_ t: String, _ text: UInt32, _ bg: UInt32, _ line: UInt32) -> some View {
        Text(t).font(.geist(11)).foregroundStyle(Color(hex: text)).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color(hex: bg)))
            .overlay(Capsule().strokeBorder(Color(hex: line), lineWidth: 1))
    }
}

/// Go live: pick the dev server; then the link, who is in it, the agent, a few settings, and End.
struct LiveCard: View {
    @ObservedObject var state: AppState
    @State private var port = ""
    @State private var copied = false
    @State private var showSettings: Bool

    init(state: AppState, settingsOpen: Bool = false) { self.state = state; _showSettings = State(initialValue: settingsOpen) }

    var body: some View {
        Group {
            if let live = state.live { on(live) }
            else if state.liveStarting { starting }
            else { picker }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }

    // MARK: Live

    private func on(_ live: LiveSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                LiveBadge()
                Text("localhost:\(String(live.upstream))").font(.geistMono(12)).foregroundStyle(Ink.muted)
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(Self.clock(ctx.date.timeIntervalSince(live.started))).font(.geistMono(12)).foregroundStyle(Ink.faint)
                }
                Button("End") { state.endLive() }.buttonStyle(EndButton()).help("End the link: guests lose access right away")
            }

            HStack(spacing: 8) {
                Image(systemName: "link").font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.faint)
                Text(Self.short(live.guestLink)).font(.geistMono(12)).foregroundStyle(Ink.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Button(copied ? "Copied" : "Copy link") {
                    state.copyLiveLink(); copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                }.buttonStyle(SmallButton(dark: true))
            }
            .padding(.leading, 10).padding(.trailing, 4).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 8).fill(Ink.field))

            HStack(spacing: 8) {
                if state.livePeople.isEmpty {
                    Image(systemName: "person.2").font(.system(size: 11)).foregroundStyle(Ink.faint).frame(width: 22)
                    Text("Nobody yet. Send the link: they use your app in their browser, point and talk.")
                        .font(.geist(12)).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: -6) { ForEach(state.livePeople.prefix(5), id: \.self) { Avatar(name: $0) } }
                    Text(Self.people(state.livePeople)).font(.geist(12)).foregroundStyle(Ink.secondary).lineLimit(2)
                }
            }

            HStack(spacing: 8) {
                Circle().fill(state.liveAgents.isEmpty ? Ink.faint : Color(hex: 0x30A46C)).frame(width: 7, height: 7).frame(width: 22)
                Text(state.liveAgents.isEmpty ? "No agent is listening yet" : "\(state.liveAgents.joined(separator: ", ")) is listening")
                    .font(.geist(12)).foregroundStyle(state.liveAgents.isEmpty ? Ink.muted : Ink.secondary)
                Spacer()
                if state.liveAgents.isEmpty {
                    Button("Copy for your agent") { state.copyAgentPrompt() }.buttonStyle(SmallButton()).help(AppState.liveAgentPrompt)
                }
            }

            Divider()

            Button { withAnimation(.easeOut(duration: 0.15)) { showSettings.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(showSettings ? 90 : 0))
                    Text("Settings").font(.geist(12, .medium))
                    if !showSettings {
                        Text("· " + Self.summary(live)).font(.geist(12)).foregroundStyle(Ink.faint).lineLimit(1)
                    }
                    Spacer()
                }
                .foregroundStyle(Ink.secondary).contentShape(Rectangle())
            }.buttonStyle(.plain)

            if showSettings {
                VStack(alignment: .leading, spacing: 10) {
                    SettingRow(title: "Send requests straight to agents", detail: live.trusted ? "Guests' requests go to the queue as they come." : "You accept each request first.",
                               on: Binding(get: { live.trusted }, set: { live.trusted = $0; state.objectWillChange.send(); Task { await live.room.settings(live) } }))
                    SettingRow(title: "Guests see only their own requests", detail: live.privateMode ? "Each guest sees what they asked for, not the others." : "Everyone in the link sees every request.",
                               on: Binding(get: { live.privateMode }, set: { live.privateMode = $0; state.objectWillChange.send(); Task { await live.room.settings(live) } }))
                    HStack {
                        Text("Your own view, with Accept").font(.geist(12)).foregroundStyle(Ink.muted)
                        Spacer()
                        Button("Open as me") { state.openLiveAsMe() }.buttonStyle(SmallButton())
                    }
                }
                .padding(.leading, 15)
            }

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "lock").font(.system(size: 10)).foregroundStyle(Ink.faint).padding(.top, 1)
                Text("Anyone with the link can use your dev server, its API routes included, until you end it. It goes through a Cloudflare tunnel.")
                    .font(.geist(11)).foregroundStyle(Ink.faint).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Starting

    private var starting: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Making the link…").font(.geist(13, .medium)).foregroundStyle(Ink.primary)
                Text("Opening a tunnel to your dev server. Usually a few seconds.").font(.geist(12)).foregroundStyle(Ink.muted)
            }
            Spacer()
        }
    }

    // MARK: Picking the dev server

    private var picker: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Go live").font(.geist(14, .medium)).foregroundStyle(Ink.primary)
                    Text("Share the app you're building. People open the link, point and talk; your agent fixes things while they watch.")
                        .font(.geist(12)).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button { state.pickingPort = false } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Ink.faint).frame(width: 20, height: 20) }
                    .buttonStyle(.plain).help("Cancel")
            }
            if !state.devServers.isEmpty {
                VStack(spacing: 6) {
                    ForEach(state.devServers.prefix(4)) { d in
                        Button { state.goLive(d.port) } label: { ServerRow(port: d.port, name: d.name) }.buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 8) {
                TextField(state.devServers.isEmpty ? "Port, e.g. 3000" : "Another port", text: $port).textFieldStyle(.roundedBorder).font(.geist(13))
                    .onSubmit { if let p = Int(port) { state.goLive(p) } }
                Button("Go live") { if let p = Int(port) { state.goLive(p) } }.buttonStyle(SmallButton(dark: true)).disabled(Int(port) == nil)
            }
        }
    }

    // MARK: Text

    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
    /// The link without its scheme: the host is what tells people it is the right one.
    static func short(_ link: String) -> String { link.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "") }
    static func people(_ p: [String]) -> String {
        switch p.count {
        case 1: return "\(p[0]) is in"
        case 2: return "\(p[0]) and \(p[1]) are in"
        default: return "\(p.prefix(2).joined(separator: ", ")) and \(p.count - 2) more are in"
        }
    }
    static func summary(_ live: LiveSession) -> String {
        [live.trusted ? "Straight to agents" : "You accept each request", live.privateMode ? "private" : nil].compactMap { $0 }.joined(separator: " · ")
    }
}

/// A red dot that breathes, and LIVE.
struct LiveBadge: View {
    @State private var pulse = false
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Ink.red).frame(width: 6, height: 6).opacity(pulse ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
            Text("LIVE").font(.geist(10, .semibold)).tracking(0.6).foregroundStyle(Ink.red)
        }
        .padding(.horizontal, 7).frame(height: 20)
        .background(Capsule().fill(Ink.red.opacity(0.1)))
        .onAppear { pulse = true }
    }
}

/// A guest's initial on a colour of their own.
struct Avatar: View {
    let name: String
    private static let colors: [UInt32] = [0x5B5BD6, 0x0D74CE, 0x2F7A4B, 0xB8860B, 0xC2298A, 0xD9480F]
    var body: some View {
        let c = Self.colors[abs(name.unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) }) % Self.colors.count]
        Text(String(name.prefix(1)).uppercased()).font(.geist(10, .semibold)).foregroundStyle(.white)
            .frame(width: 22, height: 22).background(Circle().fill(Color(hex: c)))
            .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.5))
            .help(name)
    }
}

/// A dev server found on this Mac, to go live with in one click.
struct ServerRow: View {
    let port: Int
    let name: String
    @State private var hover = false
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(hex: 0x30A46C)).frame(width: 6, height: 6)
            Text("localhost:\(String(port))").font(.geistMono(12)).foregroundStyle(Ink.primary)
            Text(name).font(.geist(12)).foregroundStyle(Ink.faint)
            Spacer()
            Text("Go live").font(.geist(12, .medium)).foregroundStyle(hover ? Ink.primary : Ink.muted)
            Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(hover ? Ink.primary : Ink.faint)
        }
        .padding(.horizontal, 10).frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 8).fill(hover ? Ink.field : Color.white))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Ink.line, lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

/// A switch with what it does now underneath.
struct SettingRow: View {
    let title: String
    let detail: String
    @Binding var on: Bool
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.geist(12)).foregroundStyle(Ink.primary)
                Text(detail).font(.geist(11)).foregroundStyle(Ink.faint).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: $on).labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
    }
}

/// End: quiet until it matters.
struct EndButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.geist(12, .medium)).foregroundStyle(Ink.red)
            .padding(.horizontal, 10).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(Ink.red.opacity(configuration.isPressed ? 0.16 : 0.08)))
            .contentShape(Rectangle())
    }
}
