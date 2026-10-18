import XCTest
import SwiftUI
import AVFoundation
@testable import UTubeMusic

@MainActor
final class ScreenCaptureTests: XCTestCase {
    private func render<V: View>(_ view: V, name: String) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = UIScreen.main.bounds
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = UIHostingController(rootView: view.preferredColorScheme(.dark).tint(Palette.accent))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        window.layoutIfNeeded()
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        XCTAssertGreaterThan(image.size.width, 300)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testCaptureNativeHome() async throws {
        let library = LibraryStore(root: try root())
        let player = PlayerStore(library: library)
        let music = MusicService(library: library)
        try await render(RootView().environmentObject(library).environmentObject(player).environmentObject(music), name: "native-home")
    }
    func testCaptureNativePlayer() async throws {
        let library = LibraryStore(root: try root())
        let url = library.root.appendingPathComponent("preview-silence.wav")
        do {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1))
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22050))
            buffer.frameLength = 22050
            if let samples = buffer.floatChannelData?[0] { for i in 0..<22050 { samples[i] = 0 } }
            for _ in 0..<60 { try file.write(from: buffer) }
        }
        let song = Song(id: "local-preview", title: "UTube Music 再生テスト", artist: "画面確認用の無音データ", duration: 60, fileName: url.lastPathComponent, favorite: true)
        try library.save(song, playlistID: nil)
        let player = PlayerStore(library: library)
        player.start([song], at: song)
        defer { player.pause() }
        try await render(NowPlayingView().environmentObject(library).environmentObject(player), name: "native-player")
    }
}
