import Foundation
import AVFoundation
import UIKit

struct EngineSong: Decodable {
    let id: String
    let title: String
    let artist: String
    let duration: Double
    let thumbnail: String?
    var song: Song { Song(id: id, title: title, artist: artist, duration: duration, thumbnail: thumbnail) }
}
struct EngineResponse: Decodable {
    let ok: Bool
    let error: String?
    let songs: [EngineSong]?
    let song: EngineSong?
    let url: String?
    let headers: [String: String]?
    let bytes: Int64?
}

final class PythonService {
    static let shared = PythonService()
    private let worker = DispatchQueue(label: "local.utubemusic.python", qos: .userInitiated)
    func request(_ values: [String: String]) async throws -> EngineResponse {
        let data = try JSONSerialization.data(withJSONObject: values)
        let text = String(decoding: data, as: UTF8.self)
        return try await withCheckedThrowingContinuation { continuation in
            worker.async {
                do {
                    guard let path = Bundle.main.resourcePath else {
                        throw AppFailure("音声取得エンジンを読み込めません。")
                    }
                    let output = try MusicPythonBridge.call(text, resourcePath: path)
                    let response = try JSONDecoder().decode(EngineResponse.self, from: Data(output.utf8))
                    guard response.ok else { throw AppFailure(response.error ?? "曲を取得できませんでした。") }
                    continuation.resume(returning: response)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

struct SaveJob: Identifiable {
    let id: UUID
    var song: Song
    var fraction: Double = 0
    var phase = "音声を確認中"
    var error: String?
    var finished = false
    var playlistID: UUID?
}

@MainActor
final class MusicService: ObservableObject {
    @Published var results: [Song] = []
    @Published var searching = false
    @Published var searchError: String?
    @Published var jobs: [SaveJob] = []
    private var searchGeneration = UUID()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private let engine = PythonService.shared
    let library: LibraryStore
    init(library: LibraryStore) { self.library = library }

    func search(_ query: String) async {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let generation = UUID(); searchGeneration = generation
        guard !query.isEmpty else { results = []; searching = false; searchError = nil; return }
        searching = true; searchError = nil; results = []
        do {
            let response = try await engine.request(["op": "search", "query": query])
            guard generation == searchGeneration, !Task.isCancelled else { return }
            results = (response.songs ?? []).map(\.song)
            searching = false
        } catch {
            guard generation == searchGeneration else { return }
            searchError = error.localizedDescription; searching = false
        }
    }
    func save(_ song: Song, favorite: Bool, playlistID: UUID?) {
        if let existing = library.song(song.id), library.isAvailable(existing) {
            do {
                if favorite && !existing.favorite { library.toggleFavorite(existing.id) }
                if let playlistID { try library.add(existing.id, to: playlistID) }
                library.message = "保存済みです。ライブラリから再生できます。"
            } catch { library.message = error.localizedDescription }
            return
        }
        guard !library.recoveryNeeded else { library.message = "ライブラリの復元が必要です。"; return }
        guard !jobs.contains(where: { $0.song.id == song.id && !$0.finished && $0.error == nil }) else {
            library.message = "この曲は保存中です。"; return
        }
        let id = UUID()
        var song = song; song.favorite = favorite
        jobs.insert(SaveJob(id: id, song: song, playlistID: playlistID), at: 0)
        tasks[id] = Task { await perform(id) }
    }
    func cancel(_ id: UUID) { tasks[id]?.cancel() }
    func dismiss(_ id: UUID) { guard tasks[id] == nil else { return }; jobs.removeAll { $0.id == id } }
    func retry(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), job.error != nil else { return }
        jobs.removeAll { $0.id == id }
        save(job.song, favorite: job.song.favorite, playlistID: job.playlistID)
    }
    private func update(_ id: UUID, _ body: (inout SaveJob) -> Void) {
        if let i = jobs.firstIndex(where: { $0.id == id }) { body(&jobs[i]) }
    }
    private func perform(_ id: UUID) async {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        let fileName = UUID().uuidString + ".m4a"
        let destination = library.root.appendingPathComponent(fileName)
        var artworkName: String?
        // Extraction requires the foreground. This assertion only grants a short grace period.
        let background = UIApplication.shared.beginBackgroundTask(withName: "Finish saving music") { [weak self] in
            Task { @MainActor in self?.cancel(id) }
        }
        defer {
            tasks[id] = nil
            if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
        }
        do {
            let response = try await engine.request(["op": "resolve", "id": job.song.id])
            try Task.checkCancellation()
            guard let urlString = response.url, let url = URL(string: urlString),
                  url.scheme == "https", let host = url.host, host.hasSuffix(".googlevideo.com"),
                  let metadata = response.song else { throw AppFailure("音声の保存先を確認できませんでした。") }
            update(id) { $0.phase = "曲を保存中" }
            try await AudioTransfer.download(url: url, headers: response.headers ?? [:], expected: response.bytes ?? 0, to: destination) { [weak self] progress in
                Task { @MainActor in self?.update(id) { $0.fraction = progress } }
            }
            try Task.checkCancellation()
            update(id) { $0.phase = "再生できるか確認中" }
            let asset = AVURLAsset(url: destination)
            let playable = try await asset.load(.isPlayable)
            let duration = try await asset.load(.duration).seconds
            let audio = try await asset.loadTracks(withMediaType: .audio)
            let video = try await asset.loadTracks(withMediaType: .video)
            guard playable, duration.isFinite, duration > 0, !audio.isEmpty, video.isEmpty else {
                throw AppFailure("保存したデータを音楽として再生できません。曲は登録されていません。")
            }
            if let thumbnail = metadata.thumbnail, let url = URL(string: thumbnail), url.scheme == "https" {
                // Artwork failure must not prevent listening. Cache it for offline use.
                artworkName = await cacheArtwork(url, id: job.song.id)
            }
            try Task.checkCancellation()
            var song = metadata.song
            song.favorite = job.song.favorite; song.duration = duration
            song.fileName = fileName; song.artworkName = artworkName
            song.bytes = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
            try library.save(song, playlistID: job.playlistID)
            update(id) { $0.song = song; $0.fraction = 1; $0.phase = "保存しました"; $0.finished = true }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            if let artworkName, let artwork = library.file(artworkName) { try? FileManager.default.removeItem(at: artwork) }
            update(id) { $0.error = error is CancellationError || (error as? URLError)?.code == .cancelled ? "保存をキャンセルしました" : error.localizedDescription }
        }
    }
    private func cacheArtwork(_ url: URL, id: String) async -> String? {
        do {
            var request = URLRequest(url: url); request.timeoutInterval = 12
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  data.count < 8_000_000, let image = UIImage(data: data), let jpg = image.jpegData(compressionQuality: 0.85) else { return nil }
            let name = UUID().uuidString + ".jpg"
            try jpg.write(to: library.root.appendingPathComponent(name), options: .atomic)
            return name
        } catch { return nil }
    }
}

enum AudioTransfer {
    // Bounded range requests avoid a single throttled googlevideo GET. Never persist an expired URL.
    static func download(url: URL, headers: [String: String], expected: Int64, to destination: URL,
                         progress: @escaping @Sendable (Double) -> Void) async throws {
        let limit: Int64 = 1_000_000_000
        guard expected <= limit else { throw AppFailure("この曲は1GBを超えるため保存できません。") }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45; config.timeoutIntervalForResource = 300
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var offset: Int64 = 0
        var total = expected
        let chunk: Int64 = 1_048_576
        repeat {
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            let end = total > 0 ? min(total - 1, offset + chunk - 1) : offset + chunk - 1
            request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
            let (temporary, response) = try await session.download(for: request)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard let http = response as? HTTPURLResponse, [200, 206].contains(http.statusCode),
                  http.url?.scheme == "https", http.url?.host?.hasSuffix(".googlevideo.com") == true else {
                throw AppFailure("曲の転送に失敗しました。もう一度保存すると取得先を更新します。")
            }
            guard !(http.mimeType ?? "").contains("text"), !(http.mimeType ?? "").contains("json") else {
                throw AppFailure("取得元が音声データを返しませんでした。")
            }
            let received = (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard received > 0, offset + received <= limit else { throw AppFailure("音声データのサイズを確認できませんでした。") }
            if http.statusCode == 206 {
                guard let range = http.value(forHTTPHeaderField: "Content-Range"), let parsed = parseRange(range),
                      parsed.start == offset, parsed.end - parsed.start + 1 == received,
                      parsed.total > parsed.end, total == 0 || total == parsed.total else {
                    throw AppFailure("曲の転送順序を確認できませんでした。再試行してください。")
                }
                total = parsed.total
                guard total <= limit else { throw AppFailure("この曲は1GBを超えるため保存できません。") }
            } else {
                guard offset == 0, total == 0 || total == received else { throw AppFailure("曲の転送が途中で途切れました。") }
                total = received
            }
            let input = try FileHandle(forReadingFrom: temporary)
            defer { try? input.close() }
            while let data = try input.read(upToCount: 262_144), !data.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: data)
            }
            offset += received
            progress(total > 0 ? Double(offset) / Double(total) : 0)
        } while offset < total
        guard offset > 0, offset == total else { throw AppFailure("音声の保存が完了しませんでした。") }
    }
    static func parseRange(_ value: String) -> (start: Int64, end: Int64, total: Int64)? {
        guard value.hasPrefix("bytes ") else { return nil }
        let fields = value.dropFirst(6).split(separator: "/")
        guard fields.count == 2, let total = Int64(fields[1]) else { return nil }
        let bounds = fields[0].split(separator: "-")
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]), start >= 0, end >= start else { return nil }
        return (start, end, total)
    }
}
