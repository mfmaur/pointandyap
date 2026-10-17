import AppKit
import SwiftUI

struct MainView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Point").font(.geist(15, .medium)).foregroundStyle(Ink.primary)
                    Text("Talk and point. Your agent gets the instructions.").font(.geist(12)).foregroundStyle(Ink.muted)
                }
            }
            .padding(.bottom, 20)

            if !state.allowed { AccessRows(state: state).padding(.bottom, 16) }

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

            Text("Or press Control twice. Rest the cursor on what you mean.")
                .font(.geist(12)).foregroundStyle(Ink.faint).padding(.top, 10)

            Text("RECENT").font(.geist(11, .medium)).foregroundStyle(Ink.faint).tracking(0.6)
                .padding(.top, 26).padding(.bottom, 6)

            if state.sessions.isEmpty {
                Text("Nothing recorded yet").font(.geist(13)).foregroundStyle(Ink.muted).padding(.vertical, 10)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(state.sessions) { row in
                            SessionRowView(row: row, state: state)
                            if row != state.sessions.last { Divider().overlay(Ink.line) }
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 400, height: 500, alignment: .topLeading)
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

    private static let time: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM, HH:mm"; return f
    }()

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.geist(13)).foregroundStyle(Ink.primary).lineLimit(1)
                Text("\(Self.time.string(from: row.date)) · \(row.duration) s")
                    .font(.geist(11)).foregroundStyle(Ink.muted)
            }
            Spacer(minLength: 8)
            if !hover { StatusPill(open: row.open, working: row.working, done: row.done) }
            if hover {
                Button { state.open(row) } label: { Image(systemName: "folder") }.buttonStyle(SmallButton())
                Button("Copy") { state.copy(row) }.buttonStyle(SmallButton(dark: true))
            }
        }
        .frame(height: 50)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { state.copy(row) }
    }
}

/// The floating pill while recording: red dot, time, Stop.
struct PillView: View {
    @ObservedObject var state: AppState
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Ink.red).frame(width: 8, height: 8)
                .opacity(pulse ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(elapsed(at: ctx.date)).font(.geistMono(13)).foregroundStyle(Ink.primary).frame(width: 40, alignment: .leading)
            }
            Button(action: state.stop) { Text("Stop  ") + Text("⌃⌃").font(.system(size: 11)).foregroundColor(Color(hex: 0x9A9DA4)) }.buttonStyle(SmallButton(dark: true))
        }
        .padding(.leading, 14).padding(.trailing, 6)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.line, lineWidth: 1))
        .onAppear { pulse = true }
    }

    private func elapsed(at now: Date) -> String {
        guard case .recording(let s) = state.phase else { return "0:00" }
        let t = max(0, Int(now.timeIntervalSince(s)))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// "2 to fix" (gold), "1 in progress" (grey) or "Done" (green), Rocky's pill colours.
struct StatusPill: View {
    let open: Int
    let working: Int
    let done: Int
    var body: some View {
        HStack(spacing: 4) {
            if working > 0 { pill("\(working) in progress", 0x3A3C41, 0xF3F3F5, 0xE3E4E7) }
            if open > 0 { pill("\(open) to fix", 0x6B5414, 0xFFF7E0, 0xF3E3B5) }
            if open == 0 && working == 0 && done > 0 { pill("Done", 0x2F7A4B, 0xF1FAF4, 0xCFE8D8) }
        }
    }

    private func pill(_ t: String, _ text: UInt32, _ bg: UInt32, _ line: UInt32) -> some View {
        Text(t).font(.geist(11)).foregroundStyle(Color(hex: text))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color(hex: bg)))
            .overlay(Capsule().strokeBorder(Color(hex: line), lineWidth: 1))
    }
}
