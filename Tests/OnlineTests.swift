import XCTest
import AVFoundation
@testable import UTubeMusic

@MainActor
final class OnlineTests: XCTestCase {
    func testOnlineRegistrationPreservesDownloadedAudioAndMemberships() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(root: root)
        let list = try library.createPlaylist("Online")
        let song = Song(id: "00000000001", title: "Online", artist: "Artist", duration: 10)
        try library.addOnline(song, favorite: true, playlistIDs: [list])
        XCTAssertTrue(library.isPlayable(try XCTUnwrap(library.song(song.id))))
        XCTAssertFalse(library.isAvailable(song))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains(where: { $0.hasSuffix("m4a") }))
        let file = root.appendingPathComponent("existing.m4a")
        let bytes = Data([1, 2, 3]); try bytes.write(to: file)
        var saved = song; saved.fileName = file.lastPathComponent
        try library.save(saved, playlistIDs: [list])
        try library.addOnline(song, favorite: false, playlistIDs: [])
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(library.songs.count, 1)
        XCTAssertEqual(library.playlists.first?.songIDs, [song.id])
        XCTAssertTrue(library.favorites.count == 1)
    }
    func testOnlineQueueShuffleRepeatAndLateResolutionCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(root: root)
        let a = Song(id: "00000000001", title: "A", artist: "Artist", duration: 10)
        let b = Song(id: "00000000002", title: "B", artist: "Artist", duration: 10)
        for song in [a,b] { try library.addOnline(song, favorite: false, playlistIDs: []) }
        var pending: CheckedContinuation<EngineResponse, Error>?
        let player = PlayerStore(library: library, request: { _ in
            try await withCheckedThrowingContinuation { pending = $0 }
        })
        defer { player.pause() }
        player.start(library.songs, at: a)
        while pending == nil { await Task.yield() }
        XCTAssertEqual(player.current?.id, a.id)
        player.toggleShuffle(); XCTAssertTrue(player.queue.shuffled)
        player.toggleRepeat(); XCTAssertEqual(player.queue.repeatMode, .all)
        player.toggleRepeat(); XCTAssertEqual(player.queue.repeatMode, .one)
        player.pause()
        let response = try JSONDecoder().decode(EngineResponse.self, from: Data(#"{"ok":true,"url":"https://r1.googlevideo.com/test"}"#.utf8))
        let first = pending; pending = nil
        first?.resume(returning: response)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(player.playing)
        player.next(); XCTAssertEqual(player.current?.id, b.id)
        player.pause()
        // Let a request that has already entered the mock finish during teardown.
        await Task.yield()
        if let pending { pending.resume(throwing: CancellationError()) }
    }
}
