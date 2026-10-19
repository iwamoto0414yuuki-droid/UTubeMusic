import XCTest
import AVFoundation
@testable import UTubeMusic

final class AudioNormalizationTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func fixture(_ name: String, in folder: URL) throws -> URL {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "audio-fixtures", withExtension: "json"))
        let values = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        let data = try XCTUnwrap(values[name].flatMap { Data(base64Encoded: $0) })
        let source = folder.appendingPathComponent(name + ".m4a")
        try data.write(to: source)
        return source
    }
    private func assertToneAndSilence(_ url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        XCTAssertEqual(Double(file.length) / rate, 3, accuracy: 0.15)
        func rms(at seconds: Double) throws -> Float {
            file.framePosition = AVAudioFramePosition(seconds * rate)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
            try file.read(into: buffer)
            let samples = try XCTUnwrap(buffer.floatChannelData?[0])
            XCTAssertGreaterThan(buffer.frameLength, 0)
            let sum = (0..<Int(buffer.frameLength)).reduce(Float(0)) { $0 + samples[$1] * samples[$1] }
            return sqrt(sum / Float(max(1, buffer.frameLength)))
        }
        XCTAssertLessThan(try rms(at: 0.8), 0.005, "Keep intentional silence inside the song")
        XCTAssertGreaterThan(try rms(at: 2.7), 0.05, "The actual ending must still contain audio")
    }
    private func packets(_ url: URL) async throws -> Data {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first), outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var bytes = Data()
        while let sample = output.copyNextSampleBuffer() {
            let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
            let length = CMBlockBufferGetDataLength(block)
            var data = Data(count: length)
            let status = data.withUnsafeMutableBytes { pointer in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: pointer.baseAddress!)
            }
            XCTAssertEqual(status, noErr)
            bytes.append(data)
        }
        XCTAssertEqual(reader.status, .completed)
        return bytes
    }
    func testRegularM4AKeepsLengthOriginalAACAndIntentionalSilence() async throws {
        let folder = try root(), source = try fixture("regular", in: folder)
        let original = try Data(contentsOf: source), destination = folder.appendingPathComponent("fixed.m4a")
        let duration = try await AudioFileNormalizer.normalize(source: source, destination: destination, expectedDuration: 3)
        XCTAssertEqual(duration, 3, accuracy: 0.15)
        XCTAssertEqual(try Data(contentsOf: source), original)
        let before = try await packets(source), after = try await packets(destination)
        XCTAssertEqual(after, before, "Remux without lossy AAC re-encoding")
        try assertToneAndSilence(destination)
    }
    func testFragmentedDASHBecomesRegularM4AWithAudibleEnding() async throws {
        let folder = try root(), source = try fixture("dash", in: folder)
        let destination = folder.appendingPathComponent("fixed.m4a")
        let duration = try await AudioFileNormalizer.normalize(source: source, destination: destination, expectedDuration: 3)
        XCTAssertEqual(duration, 3, accuracy: 0.15)
        let before = try await packets(source), after = try await packets(destination)
        XCTAssertEqual(after, before)
        try assertToneAndSilence(destination)
    }
    func testNonzeroDASHHeadersDoNotCreateSilentSecondHalf() async throws {
        let folder = try root(), source = try fixture("dash_nonzero_headers", in: folder)
        let rawDuration = try await AVURLAsset(url: source).load(.duration).seconds
        print("DASH regression: raw container duration", rawDuration, "actual audio 3 seconds")
        let destination = folder.appendingPathComponent("fixed.m4a")
        let duration = try await AudioFileNormalizer.normalize(source: source, destination: destination, expectedDuration: 3)
        XCTAssertEqual(duration, 3, accuracy: 0.15)
        try assertToneAndSilence(destination)
    }
    func testWrongSourceDurationIsRejectedAndOriginalIsKept() async throws {
        let folder = try root(), source = try fixture("dash", in: folder)
        let original = try Data(contentsOf: source), destination = folder.appendingPathComponent("fixed.m4a")
        do {
            _ = try await AudioFileNormalizer.normalize(source: source, destination: destination, expectedDuration: 30)
            XCTFail("Do not register audio with incorrect duration")
        } catch { XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path)) }
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
    func testInvalidAudioAndCancellationLeaveNoReplacement() async throws {
        let folder = try root(), source = folder.appendingPathComponent("invalid.m4a")
        try Data("invalid audio".utf8).write(to: source)
        let destination = folder.appendingPathComponent("fixed.m4a")
        do {
            _ = try await AudioFileNormalizer.normalize(source: source, destination: destination)
            XCTFail("Invalid media must fail")
        } catch { XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path)) }
        let valid = try fixture("dash", in: folder)
        let work = Task { try await AudioFileNormalizer.normalize(source: valid, destination: destination) }
        work.cancel()
        do { _ = try await work.value; XCTFail("Cancelled work must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: valid.path))
    }
    @MainActor
    func testRepairPreservesFavoritesPlaylistsOrderAndSurvivesReload() async throws {
        let folder = try root(), store = LibraryStore(root: folder)
        let source = try fixture("regular", in: folder)
        let original = try Data(contentsOf: source)
        let first = try store.createPlaylist("First"), second = try store.createPlaylist("Second")
        let song = Song(id: "AbCdEf123_-", title: "Saved", artist: "Artist", duration: 6,
                        fileName: source.lastPathComponent, favorite: true)
        try store.save(song, playlistIDs: [first, second])
        let service = MusicService(library: store)
        await service.repairSavedSongs()
        let updated = try XCTUnwrap(store.song(song.id))
        XCTAssertEqual(updated.duration, 3, accuracy: 0.15)
        XCTAssertEqual(updated.audioFileVersion, 1)
        XCTAssertTrue(updated.favorite)
        XCTAssertEqual(updated.addedAt, song.addedAt)
        XCTAssertEqual(updated.fileName, song.fileName, "Correct index only when the audio file is normal")
        XCTAssertEqual(try Data(contentsOf: source), original)
        for id in [first, second] { XCTAssertEqual(store.playlists.first(where: { $0.id == id })?.songIDs, [song.id]) }
        let reload = LibraryStore(root: folder)
        XCTAssertEqual(reload.song(song.id), updated)
        XCTAssertTrue(reload.isAvailable(updated))
        try assertToneAndSilence(try XCTUnwrap(reload.file(updated.fileName)))
        await service.repairSavedSongs()
        XCTAssertEqual(store.song(song.id)?.fileName, updated.fileName, "Already repaired files are not rewritten")
    }
    @MainActor
    func testRepairWriteFailurePreservesOriginalAndRemovesReplacement() async throws {
        let folder = try root(), store = LibraryStore(root: folder)
        let source = try fixture("dash", in: folder)
        let original = try Data(contentsOf: source)
        let song = Song(id: "AbCdEf123_-", title: "Saved", artist: "Artist", duration: 6, fileName: source.lastPathComponent)
        try store.save(song, playlistIDs: [])
        let index = try Data(contentsOf: folder.appendingPathComponent("library.json"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("library.previous.json"), withIntermediateDirectories: false)
        await MusicService(library: store).repairSavedSongs()
        XCTAssertEqual(store.song(song.id), song)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("library.json")), index)
        let audioFiles = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".m4a") }
        XCTAssertEqual(audioFiles, [source.lastPathComponent])
    }
    @MainActor
    func testPlaybackCorrectsDoubledIndexWithoutRewritingAudio() async throws {
        let folder = try root(), store = LibraryStore(root: folder)
        let source = try fixture("regular", in: folder), original = try Data(contentsOf: source)
        let song = Song(id: "AbCdEf123_-", title: "Saved", artist: "Artist", duration: 6,
                        fileName: source.lastPathComponent, favorite: true)
        try store.save(song, playlistIDs: [])
        let player = PlayerStore(library: store)
        player.start([song], at: song)
        player.pause()
        let deadline = Date().addingTimeInterval(5)
        while player.duration > 3.15 && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(player.duration, 3, accuracy: 0.15)
        XCTAssertEqual(try XCTUnwrap(player.current).duration, 3, accuracy: 0.15)
        XCTAssertEqual(try XCTUnwrap(store.song(song.id)).duration, 3, accuracy: 0.15)
        player.seek(6)
        XCTAssertLessThan(player.elapsed, 3.15, "Seek slider must not enter a phantom second half")
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
    @MainActor
    func testPlaybackAdvancesAtActualAudioEndAndRepeatOneStillWorks() async throws {
        let folder = try root(), store = LibraryStore(root: folder)
        let source = try fixture("regular", in: folder)
        let first = Song(id: "first", title: "First", artist: "Artist", duration: 6, fileName: source.lastPathComponent)
        let second = Song(id: "second", title: "Second", artist: "Artist", duration: 3,
                          fileName: source.lastPathComponent, audioFileVersion: 1)
        try store.save(first, playlistIDs: []); try store.save(second, playlistIDs: [])
        let player = PlayerStore(library: store)
        player.start([first, second], at: first)
        let deadline = Date().addingTimeInterval(5)
        while player.duration > 3.15 && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        player.seek(2.7)
        let nextDeadline = Date().addingTimeInterval(2)
        while player.current?.id == first.id && Date() < nextDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        player.pause()
        XCTAssertEqual(player.current?.id, second.id)
        player.toggleRepeat(); player.toggleRepeat()
        XCTAssertEqual(player.queue.repeatMode, .one)
        player.seek(2.7); player.play()
        try await Task.sleep(nanoseconds: 800_000_000)
        player.pause()
        XCTAssertEqual(player.current?.id, second.id)
        XCTAssertLessThan(player.elapsed, 2)
    }
    @MainActor
    func testReplacementCommitFailureDoesNotDeleteOriginal() async throws {
        let folder = try root(), store = LibraryStore(root: folder)
        let source = try fixture("regular", in: folder)
        let song = Song(id: "first", title: "First", artist: "Artist", duration: 6, fileName: source.lastPathComponent)
        try store.save(song, playlistIDs: [])
        let replacement = folder.appendingPathComponent("replacement.m4a")
        try FileManager.default.copyItem(at: source, to: replacement)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("library.previous.json"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.replaceAudio(song.id, expectedFileName: source.lastPathComponent,
                                                   newFileName: replacement.lastPathComponent, duration: 3))
        XCTAssertEqual(store.song(song.id), song)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
}
