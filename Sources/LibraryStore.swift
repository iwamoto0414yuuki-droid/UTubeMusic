import Foundation
import AVFoundation

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var songs: [Song] = []
    @Published private(set) var playlists: [MusicPlaylist] = []
    @Published var message: String?
    @Published private(set) var recoveryNeeded = false
    let root: URL
    private let database: URL
    private let fm = FileManager.default

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UTubeMusic", isDirectory: true)
        database = self.root.appendingPathComponent("library.json")
        do {
            try fm.createDirectory(at: self.root, withIntermediateDirectories: true)
            if fm.fileExists(atPath: database.path) {
                let snapshot = try JSONDecoder().decode(LibrarySnapshot.self, from: Data(contentsOf: database))
                guard snapshot.version == 1 else { throw AppFailure("このライブラリは新しいバージョン用です。アプリを更新してください。") }
                guard Set(snapshot.songs.map(\.id)).count == snapshot.songs.count,
                      Set(snapshot.playlists.map(\.id)).count == snapshot.playlists.count else {
                    throw AppFailure("ライブラリ内に重複したIDがあります。バックアップを確認してください。")
                }
                songs = snapshot.songs; playlists = snapshot.playlists
            }
        } catch {
            recoveryNeeded = true
            message = "ライブラリを読み込めません。元のファイルを保護しています。ファイルアプリでバックアップを確認してください。\n\(error.localizedDescription)"
        }
    }
    var favorites: [Song] { songs.filter(\.favorite) }
    var totalBytes: Int64 { songs.reduce(0) { $0 + $1.bytes } }
    func song(_ id: String) -> Song? { songs.first { $0.id == id } }
    func songs(in playlist: MusicPlaylist) -> [Song] { playlist.songIDs.compactMap(song) }
    func file(_ name: String?) -> URL? {
        guard let name, !name.isEmpty, name == (name as NSString).lastPathComponent, !name.contains("\\"), name != ".", name != ".." else { return nil }
        return root.appendingPathComponent(name)
    }
    func isAvailable(_ song: Song) -> Bool {
        guard let url = file(song.fileName) else { return false }
        return fm.fileExists(atPath: url.path)
    }
    func save(_ song: Song, playlistID: UUID?) throws {
        try save(song, playlistIDs: Set(playlistID.map { [$0] } ?? []))
    }
    func save(_ song: Song, playlistIDs: Set<UUID>) throws {
        try commit {
            if let i = songs.firstIndex(where: { $0.id == song.id }) {
                var updated = song
                updated.favorite = song.favorite || songs[i].favorite
                songs[i] = updated
            } else { songs.insert(song, at: 0) }
            for i in playlists.indices where playlistIDs.contains(playlists[i].id) {
                if !playlists[i].songIDs.contains(song.id) { playlists[i].songIDs.append(song.id) }
                if let order = playlists[i].sourceOrder {
                    let rank = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
                    playlists[i].songIDs = playlists[i].songIDs.enumerated().sorted {
                        let left = rank[$0.element] ?? Int.max, right = rank[$1.element] ?? Int.max
                        return left == right ? $0.offset < $1.offset : left < right
                    }.map(\.element)
                }
            }
        }
    }
    func setSourceOrder(_ ids: [String], sourceID: String, for playlistID: UUID) throws {
        try commit {
            if let i = playlists.firstIndex(where: { $0.id == playlistID }) {
                playlists[i].sourceOrder = ids; playlists[i].sourceID = sourceID
            }
        }
    }
    /// Only update the index. Repair never writes, replaces, or deletes audio files.
    func updateAudioDuration(_ id: String, expectedFileName: String, duration: Double) throws {
        guard duration.isFinite, duration > 0, let current = song(id), current.fileName == expectedFileName else {
            throw AppFailure("曲の状態が変わったため再生時間の更新を中止しました。")
        }
        try commit {
            if let index = songs.firstIndex(where: { $0.id == id }) {
                songs[index].duration = duration
                songs[index].audioTimingVersion = 1
            }
        }
    }
    @discardableResult func createPlaylist(_ name: String) throws -> UUID {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AppFailure("プレイリスト名を入力してください。") }
        let playlist = MusicPlaylist(name: String(name.prefix(100)))
        try commit { playlists.insert(playlist, at: 0) }
        return playlist.id
    }
    func renamePlaylist(_ id: UUID, name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AppFailure("プレイリスト名を入力してください。") }
        try commit { if let i = playlists.firstIndex(where: { $0.id == id }) { playlists[i].name = String(name.prefix(100)) } }
    }
    func deletePlaylist(_ id: UUID) throws { try commit { playlists.removeAll { $0.id == id } } }
    func toggleFavorite(_ id: String) {
        do { try commit { if let i = songs.firstIndex(where: { $0.id == id }) { songs[i].favorite.toggle() } } }
        catch { message = error.localizedDescription }
    }
    func add(_ id: String, to playlistID: UUID) throws {
        guard song(id) != nil else { throw AppFailure("保存済みの曲を選んでください。") }
        try commit {
            if let i = playlists.firstIndex(where: { $0.id == playlistID }), !playlists[i].songIDs.contains(id) { playlists[i].songIDs.append(id) }
        }
    }
    func remove(_ id: String, from playlistID: UUID) throws {
        try commit { if let i = playlists.firstIndex(where: { $0.id == playlistID }) { playlists[i].songIDs.removeAll { $0 == id } } }
    }
    func move(in playlistID: UUID, from: IndexSet, to: Int) throws {
        try commit {
            guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
            var ids = playlists[i].songIDs
            let moving = from.sorted().compactMap { ids.indices.contains($0) ? ids[$0] : nil }
            for index in from.sorted(by: >) where ids.indices.contains(index) { ids.remove(at: index) }
            let destination = min(ids.count, max(0, to - from.filter { $0 < to }.count))
            ids.insert(contentsOf: moving, at: destination)
            playlists[i].songIDs = ids
            playlists[i].sourceOrder = nil
        }
    }
    func delete(_ song: Song) throws {
        // Commit the index first. A failed database write must never lose the audio file.
        try commit {
            songs.removeAll { $0.id == song.id }
            for i in playlists.indices { playlists[i].songIDs.removeAll { $0 == song.id } }
        }
        for name in [song.fileName, song.artworkName] {
            if let url = file(name), fm.fileExists(atPath: url.path) {
                do { try fm.removeItem(at: url) }
                catch { message = "曲の登録は削除しましたが、ファイルの削除に失敗しました：\(error.localizedDescription)" }
            }
        }
    }
    func importAudio(_ url: URL) async throws {
        guard !recoveryNeeded else { throw AppFailure("ライブラリの復元が必要です。") }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.lowercased()
        guard ["m4a", "mp3", "aac", "wav", "aif", "aiff", "caf"].contains(ext) else { throw AppFailure("M4A・MP3などの音声ファイルを選んでください。") }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, try await asset.load(.isPlayable) else { throw AppFailure("この音声を再生できません。") }
        let id = "local-" + UUID().uuidString
        let name = id + "." + ext
        let target = root.appendingPathComponent(name)
        try fm.copyItem(at: url, to: target)
        do {
            let bytes = (try fm.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value ?? 0
            try save(Song(id: id, title: url.deletingPathExtension().lastPathComponent, artist: "読み込んだ曲", duration: duration, fileName: name, bytes: bytes), playlistID: nil)
        } catch { try? fm.removeItem(at: target); throw error }
    }
    private func commit(_ mutation: () -> Void) throws {
        guard !recoveryNeeded else { throw AppFailure("元のライブラリを保護しています。復元してから操作してください。") }
        let oldSongs = songs, oldPlaylists = playlists
        mutation()
        do {
            let data = try JSONEncoder().encode(LibrarySnapshot(songs: songs, playlists: playlists))
            if fm.fileExists(atPath: database.path) {
                // The previous valid index remains available alongside the audio in Files.
                try Data(contentsOf: database).write(to: root.appendingPathComponent("library.previous.json"), options: .atomic)
            }
            try data.write(to: database, options: .atomic)
        } catch { songs = oldSongs; playlists = oldPlaylists; throw error }
    }
}
