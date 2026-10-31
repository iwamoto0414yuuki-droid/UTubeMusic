import XCTest
import AVFoundation
@testable import UTubeMusic

final class LoudnessMeterTests: XCTestCase {
    func testReferenceToneAcrossRatesAndChannels() {
        // BS.1770 997 Hz reference: full-scale mono sine = -3.01 LKFS.
        for rate in [44100.0, 48000.0] {
            for channels in [1, 2] {
                var meter = LoudnessMeter(rate: rate, channels: channels)
                for n in 0..<Int(rate * 3) {
                    let sample = 0.5 * sin(2 * .pi * 997 * Double(n) / rate)
                    for ch in 0..<channels { meter.add(sample, channel: ch) }
                    meter.endFrame()
                }
                XCTAssertEqual(meter.integrated ?? 0, channels == 1 ? -9.03 : -6.02, accuracy: 0.12)
            }
        }
    }
    func testGatingIgnoresLongSilenceAndSilenceNeverAmplifies() {
        var meter = LoudnessMeter(rate: 48000, channels: 1)
        for n in 0..<48000 * 8 {
            meter.add(n < 48000 * 4 ? 0.5 * sin(2 * .pi * 997 * Double(n) / 48000) : 0, channel: 0)
            meter.endFrame()
        }
        XCTAssertEqual(meter.integrated ?? 0, -9.03, accuracy: 0.3)
        XCTAssertEqual(Loudness.volume(lufs: nil), 1)
        for value in [-30.0, -14, .nan, .infinity, 100] { XCTAssertEqual(Loudness.volume(lufs: value), 1) }
        XCTAssertEqual(Loudness.volume(lufs: -8), Float(pow(10, -6.0 / 20)), accuracy: 0.0001)
        XCTAssertEqual(Loudness.sourceVolume(6), Loudness.volume(lufs: -8))
        XCTAssertEqual(Loudness.sourceVolume(-5), 1)
    }
}

@MainActor
final class LoudnessPlaybackTests: XCTestCase {
    private func fixture() throws -> (LibraryStore, Song) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LibraryStore(root: root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("tone.wav")
        do {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000))
            buffer.frameLength = 48000
            for n in 0..<48000 { buffer.floatChannelData![0][n] = Float(0.5 * sin(2 * .pi * 997 * Double(n) / 48000)) }
            for _ in 0..<3 { try file.write(from: buffer) }
        }
        let song = Song(id: "00000000001", title: "Tone", artist: "Test", duration: 3, fileName: "tone.wav", favorite: true, audioTimingVersion: 1)
        let list = try store.createPlaylist("Keep")
        try store.save(song, playlistIDs: [list])
        return (store, song)
    }
    func testReadAndCacheLeaveAudioAndMembershipsUntouched() async throws {
        let (store, song) = try fixture()
        let url = try XCTUnwrap(store.file(song.fileName)), before = try Data(contentsOf: url), lists = store.playlists
        let lufs = try await Loudness.read(url)
        XCTAssertEqual(try XCTUnwrap(lufs), -9.03, accuracy: 0.12)
        try store.cacheLoudness(song.id, fileName: "tone.wav", lufs: lufs)
        try store.cacheLoudness(song.id, fileName: "stale.wav", lufs: -30)
        let reload = LibraryStore(root: store.root)
        XCTAssertEqual(reload.song(song.id)?.measuredLoudness, lufs)
        XCTAssertEqual(reload.playlists, lists); XCTAssertTrue(try XCTUnwrap(reload.song(song.id)).favorite)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }
    func testPauseDuringFirstAnalysisDoesNotAutoplayAndCachedReplayAttenuates() async throws {
        let (store, song) = try fixture()
        let player = PlayerStore(library: store)
        player.normalizeVolume = true
        defer { player.pause(); UserDefaults.standard.removeObject(forKey: "normalizeVolume") }
        player.start([song], at: song); player.pause()
        for _ in 0..<200 { if !player.preparingVolume { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(player.preparingVolume); XCTAssertFalse(player.playing)
        XCTAssertLessThan(player.playbackVolume, 0.6)
        XCTAssertNotNil(store.song(song.id)?.loudnessFileName)
        player.start([song], at: song)
        XCTAssertFalse(player.preparingVolume); XCTAssertLessThan(player.playbackVolume, 0.6)
        player.normalizeVolume = false; XCTAssertEqual(player.playbackVolume, 1)
    }
    func testOnlineAttenuationIsAppliedBeforeStartingWithoutSavingAudio() async throws {
        let (store, original) = try fixture()
        let online = Song(id: "00000000002", title: "Online", artist: "Test", duration: 3)
        try store.addOnline(online, favorite: true, playlistIDs: [])
        let data = Data(#"{"ok":true,"url":"https://r1.googlevideo.com/audio","loudness_db":6}"#.utf8)
        let response = try JSONDecoder().decode(EngineResponse.self, from: data)
        let player = PlayerStore(library: store, request: { _ in response }, streamItem: { _, _ in AVPlayerItem(url: store.file(original.fileName)!) })
        player.normalizeVolume = true
        defer { player.pause(); UserDefaults.standard.removeObject(forKey: "normalizeVolume") }
        player.start([online], at: online)
        for _ in 0..<100 { if player.playing { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(player.playing); XCTAssertEqual(player.playbackVolume, 0.501187, accuracy: 0.0001)
        XCTAssertEqual(store.song(online.id)?.sourceLoudnessDB, 6); XCTAssertNil(store.song(online.id)?.fileName)
    }
}
