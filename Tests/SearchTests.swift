import XCTest
@testable import UTubeMusic

@MainActor
final class SearchTests: XCTestCase {
    private func response(_ ids: [String], offset: Int, more: Bool) throws -> EngineResponse {
        let songs = ids.map { ["id": $0, "title": $0, "artist": "Artist", "duration": 10] as [String: Any] }
        let data = try JSONSerialization.data(withJSONObject: ["ok": true, "songs": songs, "next_offset": offset, "has_more": more])
        return try JSONDecoder().decode(EngineResponse.self, from: data)
    }
    func testMoreAppendsDeduplicatesAndKeepsResultsOnRetryableFailure() async throws {
        var calls = 0
        let store = SongSearchStore { values in
            calls += 1
            if calls == 1 { return try self.response(["a", "b"], offset: 20, more: true) }
            XCTAssertEqual(values["offset"], "20")
            if calls == 2 { throw AppFailure("Offline") }
            return try self.response(["b", "c"], offset: 40, more: false)
        }
        await store.search("Test"); await store.loadMore()
        XCTAssertEqual(store.results.map(\.id), ["a", "b"])
        XCTAssertEqual(store.moreError, "Offline"); XCTAssertTrue(store.hasMore)
        await store.loadMore()
        XCTAssertEqual(store.results.map(\.id), ["a", "b", "c"])
        XCTAssertNil(store.moreError); XCTAssertFalse(store.hasMore)
    }
    func testOldSearchCannotOverwriteNewQuery() async throws {
        var pending: CheckedContinuation<EngineResponse, Error>?
        let store = SongSearchStore { values in
            if values["query"] == "old" { return try await withCheckedThrowingContinuation { pending = $0 } }
            return try self.response(["new"], offset: 20, more: false)
        }
        let first = Task { await store.search("old") }
        while pending == nil { await Task.yield() }
        await store.search("new")
        pending?.resume(returning: try response(["old"], offset: 20, more: true))
        await first.value
        XCTAssertEqual(store.results.map(\.id), ["new"]); XCTAssertFalse(store.hasMore)
    }
    func testClearingDuringLoadMoreCannotRepopulateResults() async throws {
        var pending: CheckedContinuation<EngineResponse, Error>?
        let store = SongSearchStore { values in
            if values["offset"] == "20" { return try await withCheckedThrowingContinuation { pending = $0 } }
            return try self.response(["a"], offset: 20, more: true)
        }
        await store.search("Song")
        let more = Task { await store.loadMore() }
        while pending == nil { await Task.yield() }
        await store.search("")
        pending?.resume(returning: try response(["b"], offset: 40, more: true))
        await more.value
        XCTAssertTrue(store.results.isEmpty); XCTAssertFalse(store.loadingMore); XCTAssertFalse(store.searching)
    }
    func testCollectionLinksAreExplicitAndDoNotCaptureSingleSongs() {
        XCTAssertEqual(CatalogItem.link("https://music.youtube.com/browse/MPREb_album")?.kind, "album")
        XCTAssertEqual(CatalogItem.link("https://music.youtube.com/playlist?list=PL12345")?.id, "PL12345")
        XCTAssertNil(CatalogItem.link("https://music.youtube.com.evil.test/playlist?list=PL12345"))
        XCTAssertNil(CatalogItem.link("https://music.youtube.com/watch?v=AbCdEf123_-&list=PL12345"))
    }
}
