import XCTest
@testable import UTubeMusic

final class QueueTests: XCTestCase {
    func testSequentialStopsAtEndAndManualNextOverridesRepeatOne() {
        var q = PlaybackQueue(); q.start(["a", "b", "c"], at: "a")
        q.repeatMode = .one
        XCTAssertEqual(q.advance(automatically: true), "a")
        XCTAssertEqual(q.advance(automatically: false), "b")
        q.repeatMode = .off
        XCTAssertEqual(q.advance(automatically: true), "c")
        XCTAssertNil(q.advance(automatically: true))
    }
    func testRepeatAllWrapsAndPreviousRetracesShuffle() {
        var q = PlaybackQueue(); q.start(["a", "b", "c", "d"], at: "c", shuffle: true)
        XCTAssertEqual(q.current, "c")
        XCTAssertEqual(Set(q.order), Set(["a", "b", "c", "d"]))
        let second = q.advance(automatically: false)
        XCTAssertEqual(q.previous(), "c")
        XCTAssertEqual(q.advance(automatically: false), second)
        q.repeatMode = .all
        _ = q.advance(automatically: true); _ = q.advance(automatically: true)
        let last = q.current
        XCTAssertNotEqual(q.advance(automatically: true), last)
    }
    func testShuffleOffPreservesCurrentAndRemovalPreservesPosition() {
        var q = PlaybackQueue(); q.start(["a", "b", "b", "c"], at: "b")
        q.toggleShuffle(); q.toggleShuffle()
        XCTAssertEqual(q.current, "b"); XCTAssertEqual(q.order, ["a", "b", "c"])
        q.remove("a"); XCTAssertEqual(q.current, "b")
        q.remove("b"); XCTAssertEqual(q.current, "c")
        q.remove("c"); XCTAssertNil(q.current)
    }
    func testEmptyAndSingleSongQueues() {
        var q = PlaybackQueue(); XCTAssertNil(q.advance(automatically: false))
        q.start(["a"], at: "a", shuffle: true); q.repeatMode = .all
        XCTAssertEqual(q.advance(automatically: true), "a")
        q.append("a"); XCTAssertEqual(q.order, ["a"])
    }
    func testRangeValidation() {
        XCTAssertEqual(AudioTransfer.parseRange("bytes 0-99/100")?.total, 100)
        XCTAssertEqual(AudioTransfer.parseRange("bytes 100-199/200")?.start, 100)
        XCTAssertNil(AudioTransfer.parseRange("bytes */100"))
        XCTAssertNil(AudioTransfer.parseRange("bytes 9-2/100"))
        XCTAssertNil(AudioTransfer.parseRange("bytes -1-2/100"))
        XCTAssertNil(AudioTransfer.parseRange("garbage"))
    }
}

@MainActor
final class LibraryTests: XCTestCase {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testDeleteRemovesFileAndPlaylistReferencesAndAllowsResave() throws {
        let root = try makeRoot(), store = LibraryStore(root: root)
        let file = root.appendingPathComponent("song.m4a")
        try Data([1, 2, 3]).write(to: file)
        let song = Song(id: "song", title: "Title", artist: "Artist", duration: 100, fileName: "song.m4a")
        let playlist = try store.createPlaylist("My music")
        try store.save(song, playlistID: playlist)
        try store.add(song.id, to: playlist)
        XCTAssertEqual(store.playlists[0].songIDs.count, 1)
        try store.delete(song)
        XCTAssertTrue(store.songs.isEmpty); XCTAssertTrue(store.playlists[0].songIDs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try Data([4]).write(to: file)
        try store.save(song, playlistID: playlist)
        XCTAssertEqual(store.songs.count, 1)
        let reloaded = LibraryStore(root: root)
        XCTAssertEqual(reloaded.songs[0].id, song.id)
        XCTAssertEqual(reloaded.playlists[0].songIDs, [song.id])
    }
    func testCorruptIndexIsNeverOverwritten() throws {
        let root = try makeRoot(), url = root.appendingPathComponent("library.json")
        let original = Data("not JSON".utf8); try original.write(to: url)
        let store = LibraryStore(root: root)
        XCTAssertTrue(store.recoveryNeeded)
        XCTAssertThrowsError(try store.createPlaylist("New"))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    func testWriteFailureRollsBackStateAndKeepsAudio() throws {
        let root = try makeRoot(), store = LibraryStore(root: root)
        let song = Song(id: "a", title: "A", artist: "B", duration: 10, fileName: "a.m4a")
        try Data([1]).write(to: root.appendingPathComponent("a.m4a"))
        try store.save(song, playlistID: nil)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("library.previous.json"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.delete(song))
        XCTAssertEqual(store.songs.count, 1); XCTAssertTrue(store.isAvailable(song))
    }
    func testPlaylistReorderAndDeleteKeepSongs() throws {
        let store = LibraryStore(root: try makeRoot())
        let id = try store.createPlaylist("Mix")
        for key in ["a", "b", "c", "d"] { try store.save(Song(id: key, title: key, artist: "Artist", duration: 1), playlistID: id) }
        try store.move(in: id, from: IndexSet([0, 2]), to: 4)
        XCTAssertEqual(store.playlists[0].songIDs, ["b", "d", "a", "c"])
        try store.deletePlaylist(id)
        XCTAssertEqual(store.songs.count, 4); XCTAssertTrue(store.playlists.isEmpty)
    }
    func testUntrustedFileNamesStayInsideLibrary() throws {
        let store = LibraryStore(root: try makeRoot())
        for path in ["../escape", "/tmp/escape", "..", "a\\b", ""] { XCTAssertNil(store.file(path)) }
        XCTAssertEqual(store.file("safe.m4a")?.deletingLastPathComponent(), store.root)
    }
}
