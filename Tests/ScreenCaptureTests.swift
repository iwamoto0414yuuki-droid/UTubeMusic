import XCTest
import SwiftUI
import AVFoundation
@testable import UTubeMusic

@MainActor
final class ScreenCaptureTests: XCTestCase {
    private func render<V: View>(_ view: V, name: String, scrollToBottom: Bool = false, inspect: ((UIWindow) -> Void)? = nil) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844) // iPhone 14 viewport.
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = UIHostingController(rootView: view.preferredColorScheme(.dark).tint(Palette.accent))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        window.layoutIfNeeded()
        if scrollToBottom {
            func scrolls(_ view: UIView) -> [UIScrollView] {
                (view as? UIScrollView).map { [$0] } ?? [] + view.subviews.flatMap(scrolls)
            }
            let candidates = scrolls(window).filter { $0.contentSize.height > $0.bounds.height + 20 && $0.contentSize.width <= $0.bounds.width + 2 }
            let scroll = try XCTUnwrap(candidates.max(by: { $0.contentSize.height < $1.contentSize.height }))
            let end = max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            scroll.setContentOffset(CGPoint(x: 0, y: end), animated: false)
            try await Task.sleep(nanoseconds: 500_000_000)
            window.layoutIfNeeded()
        }
        inspect?(window)
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
        let catalog = CatalogStore { _ in
            let data = Data(#"{"ok":true,"sections":[{"id":"public","title":"見つけるプレイリスト","items":[{"id":"PLpreview01","kind":"playlist","title":"Chill & Relax","subtitle":"画面確認用","thumbnail":null},{"id":"MPREb_preview","kind":"album","title":"Piano Collection","subtitle":"画面確認用","thumbnail":null}]}]}"#.utf8)
            return try JSONDecoder().decode(EngineResponse.self, from: data)
        }
        try await render(RootView(homeCatalog: catalog).environmentObject(library).environmentObject(player).environmentObject(music), name: "native-home")
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
    private func playableLibrary() throws -> (LibraryStore, PlayerStore, MusicService, Song) {
        let library = LibraryStore(root: try root())
        let url = library.root.appendingPathComponent("layout-silence.wav")
        do {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1))
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22050))
            buffer.frameLength = 22050
            if let samples = buffer.floatChannelData?[0] { for i in 0..<22050 { samples[i] = 0 } }
            for _ in 0..<60 { try file.write(from: buffer) }
        }
        let song = Song(id: "local-layout", title: "お気に入りのピアノ", artist: "画面確認用の無音データ", duration: 60, fileName: url.lastPathComponent, favorite: true)
        let list = try library.createPlaylist("夜に聴きたい曲")
        try library.save(song, playlistID: list)
        let player = PlayerStore(library: library)
        player.start([song], at: song)
        return (library, player, MusicService(library: library), song)
    }
    func testCaptureSearchDuringPlaybackAndLastGenreAbovePlayer() async throws {
        let (library, player, music, _) = try playableLibrary()
        defer { player.pause() }
        var frames: [String: CGRect] = [:]
        let view = RootView(initialTab: 1).environmentObject(library).environmentObject(player).environmentObject(music)
            .onPreferenceChange(PlayerLayoutFrames.self) { frames = $0 }
        try await render(view, name: "native-search-bottom", scrollToBottom: true) { _ in
            guard let content = frames["content"], let chrome = frames["chrome"], let piano = frames["genre-7"] else {
                XCTFail("Missing measured layout regions: \(frames.keys)"); return
            }
            XCTAssertLessThanOrEqual(content.maxY, chrome.minY + 1)
            XCTAssertGreaterThan(chrome.height, 100, "Mini player and navigation must reserve their full height")
            XCTAssertLessThanOrEqual(piano.maxY, chrome.minY - 12, "Piano button must be visible without overscrolling")
            XCTAssertGreaterThan(piano.minY, content.minY)
        }
    }
    func testCaptureSearchPlaying() async throws {
        let (library, player, music, _) = try playableLibrary()
        defer { player.pause() }
        try await render(RootView(initialTab: 1).environmentObject(library).environmentObject(player).environmentObject(music), name: "native-search-playing")
    }
    func testCaptureSaveChoices() async throws {
        let (library, player, music, song) = try playableLibrary()
        defer { player.pause() }
        try library.createPlaylist("通学のおとも")
        try await render(SaveSongSheet(song: song).environmentObject(library).environmentObject(player).environmentObject(music), name: "native-save")
    }
    func testCaptureLibraryPlaying() async throws {
        let (library, player, music, _) = try playableLibrary()
        defer { player.pause() }
        try await render(RootView(initialTab: 2).environmentObject(library).environmentObject(player).environmentObject(music), name: "native-library")
    }
}
