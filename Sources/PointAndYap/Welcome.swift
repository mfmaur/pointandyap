import AVFoundation
import AppKit
import SwiftUI

/// The first-run card: a 9 s loop of how it works (Resources/Welcome/welcome.mp4, rendered from site/film/welcome.html),
/// muted, with Got it. Shown once the permissions are allowed, until Got it; How it works brings it back.
struct WelcomeCard: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 10) {
            Group {
                if RenderUI.active, let p = Bundle.main.url(forResource: "welcome-poster", withExtension: "png", subdirectory: "Welcome"),
                   let img = NSImage(contentsOf: p) {
                    Image(nsImage: img).resizable()   // offscreen renders cannot draw a player
                } else {
                    LoopingVideo(name: "welcome")
                }
            }
                .frame(width: 352, height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.line, lineWidth: 1))
                .accessibilityLabel("How it works: press Control twice, point at something and say what is wrong, press Control twice again; your coding agent fixes it and marks it done.")
            HStack {
                Text("Control twice, point and talk, Control twice.").font(.geist(12)).foregroundStyle(Ink.muted)
                Spacer()
                Button("Got it") { state.dismissWelcome() }.buttonStyle(SmallButton(dark: true))
            }
        }
    }
}

/// A muted video that loops, with its poster frame underneath until the first frame shows.
struct LoopingVideo: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> PlayerView { PlayerView(name: name) }
    func updateNSView(_ view: PlayerView, context: Context) {}

    final class PlayerView: NSView {
        private let player = AVQueuePlayer()
        private var looper: AVPlayerLooper?
        private let layerPlayer = AVPlayerLayer()

        init(name: String) {
            super.init(frame: .zero)
            wantsLayer = true
            if let poster = Bundle.main.url(forResource: "\(name)-poster", withExtension: "png", subdirectory: "Welcome"),
               let image = NSImage(contentsOf: poster) {
                layer?.contents = image
                layer?.contentsGravity = .resizeAspectFill
            }
            layerPlayer.player = player
            layerPlayer.videoGravity = .resizeAspectFill
            layer?.addSublayer(layerPlayer)
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            if let url = Bundle.main.url(forResource: name, withExtension: "mp4", subdirectory: "Welcome") {
                looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
                player.play()
            }
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            layerPlayer.frame = bounds
        }
    }
}
