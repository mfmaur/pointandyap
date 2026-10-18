import AppKit
import ServiceManagement
import SwiftUI

/// The app's settings, kept in its defaults (com.marcmaurer.pointandyap).
enum Prefs {
    static var sounds: Bool { flag("sounds") }
    static var doubleControl: Bool { flag("doubleControl") }
    static var escCancels: Bool { flag("escCancels") }
    /// Off until the user says yes on the first-run question (or in Settings).
    static var connectAgents: Bool { flag("connectAgents", default: false) }

    /// Every other switch is on until it is turned off.
    private static func flag(_ k: String, default d: Bool = true) -> Bool { UserDefaults.standard.object(forKey: k) as? Bool ?? d }

    static let languages: [(id: String, name: String)] = [
        ("", "Same as the Mac"), ("en-US", "English"), ("de-DE", "German"), ("fr-FR", "French"), ("es-ES", "Spanish"),
        ("it-IT", "Italian"), ("pt-BR", "Portuguese"), ("nl-NL", "Dutch"), ("ja-JP", "Japanese"), ("zh-CN", "Chinese"),
    ]
}

struct SettingsView: View {
    @ObservedObject var state: AppState
    @AppStorage("sounds") private var sounds = true
    @AppStorage("doubleControl") private var doubleControl = true
    @AppStorage("escCancels") private var escCancels = true
    @AppStorage("connectAgents") private var connectAgents = false
    @AppStorage("locale") private var locale = ""
    @AppStorage("showNoSpeech") private var showNoSpeech = false
    @State private var atLogin = SMAppService.mainApp.status == .enabled
    @State private var agents = AgentInstall.status()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { state.showSettings = false } label: {
                    HStack(spacing: 4) { Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold)); Text("Back") }
                }.buttonStyle(SmallButton())
                Spacer()
                Text("Settings").font(.geist(15, .medium)).foregroundStyle(Ink.primary)
                Spacer()
                Color.clear.frame(width: 60, height: 1)
            }
            .padding(.bottom, 4)

            section("Recording")
            group {
                toggle("Sounds", "A soft sound at start and when it is copied", $sounds)
                line
                toggle("Control twice", "Starts and stops a recording from any app", $doubleControl)
                line
                toggle("Esc cancels", "Stops and moves the recording to the Trash", $escCancels)
                line
                HStack {
                    Text("Show recordings without speech").font(.geist(13)).foregroundStyle(Ink.primary)
                    Spacer()
                    Toggle("", isOn: $showNoSpeech).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }.frame(height: 40)
                line
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Speech language").font(.geist(13)).foregroundStyle(Ink.primary)
                        Text("Transcribed on this Mac").font(.geist(11)).foregroundStyle(Ink.muted)
                    }
                    Spacer()
                    Picker("", selection: $locale) {
                        ForEach(Prefs.languages, id: \.id) { Text($0.name).tag($0.id) }
                    }.labelsHidden().frame(width: 150)
                }.frame(height: 46)
            }

            section("Coding agents")
            group {
                toggle("Connect automatically", "Adds the MCP and skill to your coding agents", $connectAgents)
                line
                HStack {
                    Text(agents.isEmpty ? "No agents found" : agents.map { "\($0.name) \($0.on ? "✓" : "–")" }.joined(separator: "   "))
                        .font(.geist(12)).foregroundStyle(Ink.muted).lineLimit(1)
                    Spacer()
                    Button("Connect now") {
                        DispatchQueue.global(qos: .userInitiated).async {
                            AgentInstall.run(force: true)
                            let s = AgentInstall.status()
                            DispatchQueue.main.async { agents = s }
                        }
                    }.buttonStyle(SmallButton())
                }.frame(height: 40)
            }

            section("General")
            group {
                HStack {
                    Text("Open at login").font(.geist(13)).foregroundStyle(Ink.primary)
                    Spacer()
                    Toggle("", isOn: $atLogin).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .onChange(of: atLogin) { _, on in
                            do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                            catch { atLogin = SMAppService.mainApp.status == .enabled }
                        }
                }.frame(height: 40)
                line
                HStack {
                    Text("Version \(Updater.shared.version)").font(.geist(13)).foregroundStyle(Ink.primary)
                    Spacer()
                    Button("Check for updates") { Updater.shared.checkNow() }.buttonStyle(SmallButton())
                }.frame(height: 40)
                line
                HStack {
                    Text("Recordings").font(.geist(13)).foregroundStyle(Ink.primary)
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.open(Paths.root) }.buttonStyle(SmallButton())
                }.frame(height: 40)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 400, height: 590, alignment: .topLeading)
        .background(Color.white)
    }

    private var line: some View { Divider().overlay(Ink.line) }

    private func section(_ t: String) -> some View {
        Text(t).font(.geist(11, .medium)).foregroundStyle(Ink.faint).tracking(0.6).padding(.top, 8).padding(.bottom, 6)
    }

    private func group<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(spacing: 0, content: c).padding(.horizontal, 12).background(RoundedRectangle(cornerRadius: 10).fill(Ink.field))
    }

    private func toggle(_ title: String, _ sub: String, _ on: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.geist(13)).foregroundStyle(Ink.primary)
                Text(sub).font(.geist(11)).foregroundStyle(Ink.muted)
            }
            Spacer()
            Toggle("", isOn: on).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }.frame(height: 46)
    }
}
