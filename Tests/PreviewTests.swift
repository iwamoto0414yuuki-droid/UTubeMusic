import XCTest
import AVFoundation
@testable import UTubeMusic

@MainActor
final class PreviewTests: XCTestCase {
    private let song = Song(id: "AbCdEf123_-", title: "Preview", artist: "Artist", duration: 180)
    private func response(_ text: String) throws -> EngineResponse {
        try JSONDecoder().decode(EngineResponse.self, from: Data(text.utf8))
    }
    private func fixture() throws -> URL {
        let json = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "audio-fixtures", withExtension: "json"))
        let values = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: json))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        try XCTUnwrap(values["regular"].flatMap { Data(base64Encoded: $0) }).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try AVAudioSession.sharedInstance().setCategory(.playback)
        return url
    }
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Preview state did not settle")
    }
    func testPreviewRejectsInvalidRangesAndLimitsShortSongs() throws {
        for pair in [(Double.nan, 15.0), (-1, 2), (5, 4), (0, 16), (0, Double.infinity)] {
            XCTAssertThrowsError(try PreviewWindow(start: pair.0, end: pair.1, kind: "middle"))
        }
        let short = try PreviewWindow.middle(duration: 3)
        XCTAssertEqual(short.start, 0); XCTAssertEqual(short.end, 3)
        XCTAssertEqual(try PreviewWindow.middle(duration: 180).start, 72)
    }
    func testRemoteExcerptAutomaticallyEndsResumesOnceAndPreservesFile() async throws {
        let url = try fixture(), bytes = try Data(contentsOf: url)
        var suspended = 0, resumed = 0, errors = [String](), created = 0
        let metadata = try response(#"{"ok":true,"url":"https://r1.googlevideo.com/test","preview_start":0.2,"preview_end":0.7,"preview_kind":"chorus","headers":{"User-Agent":"test"}}"#)
        let preview = PreviewController(request: { request in
            XCTAssertEqual(request["op"], "preview"); return metadata
        }, itemFactory: { _, headers in
            XCTAssertEqual(headers["User-Agent"], "test"); created += 1
            return AVPlayerItem(url: url)
        }, suspendMain: { suspended += 1; return true }, resumeMain: { resumed += 1 }, onError: { errors.append($0) })
        preview.toggle(song)
        try await waitFor { created == 1 }
        try await waitFor { preview.song == nil }
        XCTAssertEqual(suspended, 1); XCTAssertEqual(resumed, 1); XCTAssertTrue(errors.isEmpty)
        XCTAssertFalse(preview.loading); XCTAssertEqual(try Data(contentsOf: url), bytes)
        preview.stop(); XCTAssertEqual(resumed, 1)
    }
    func testSavedPreviewWorksWithoutNetworkAndKeepsPausedMainPaused() async throws {
        let url = try fixture()
        var requests = 0, resumed = 0, errors = [String]()
        let preview = PreviewController(request: { _ in requests += 1; throw AppFailure("Must stay offline") },
            suspendMain: { false }, resumeMain: { resumed += 1 }, onError: { errors.append($0) })
        preview.toggle(song, localURL: url)
        try await waitFor { !preview.loading }
        XCTAssertNotNil(preview.song); XCTAssertEqual(preview.window?.start, 0)
        XCTAssertEqual(try XCTUnwrap(preview.window?.end), 3, accuracy: 0.15)
        preview.stop(); XCTAssertEqual(requests, 0); XCTAssertEqual(resumed, 0); XCTAssertTrue(errors.isEmpty)
    }
    func testCancelledLookupCannotStartOrResumeAfterMainTakesOver() async throws {
        var continuation: CheckedContinuation<EngineResponse, Error>?
        var created = 0, resumed = 0
        let preview = PreviewController(request: { _ in
            try await withCheckedThrowingContinuation { continuation = $0 }
        }, itemFactory: { _, _ in created += 1; return AVPlayerItem(url: URL(fileURLWithPath: "/unused")) },
            suspendMain: { true }, resumeMain: { resumed += 1 }, onError: { _ in XCTFail("Cancelled lookup showed error") })
        preview.toggle(song)
        try await waitFor { continuation != nil }
        preview.stop(resume: false)
        continuation?.resume(returning: try response(#"{"ok":true,"url":"https://r1.googlevideo.com/test","preview_start":0,"preview_end":1}"#))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(preview.song); XCTAssertFalse(preview.loading)
        XCTAssertEqual(created, 0); XCTAssertEqual(resumed, 0)
    }
    func testInvalidSourceFailsBeforePlaybackAndRestoresMain() async throws {
        var errors = [String](), resumed = 0, created = 0
        let metadata = try response(#"{"ok":true,"url":"https://example.com/audio","preview_start":0,"preview_end":15}"#)
        let preview = PreviewController(request: { _ in metadata }, itemFactory: { _, _ in
            created += 1; return AVPlayerItem(url: URL(fileURLWithPath: "/unused"))
        }, suspendMain: { true }, resumeMain: { resumed += 1 }, onError: { errors.append($0) })
        preview.toggle(song)
        try await waitFor { !errors.isEmpty }
        XCTAssertNil(preview.song); XCTAssertFalse(preview.loading)
        XCTAssertEqual(created, 0); XCTAssertEqual(resumed, 1); XCTAssertEqual(errors.count, 1)
    }
}
