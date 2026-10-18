import SwiftUI
import UniformTypeIdentifiers

struct SaveSongSheet: View {
    let song: Song
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var music: MusicService
    @Environment(\.dismiss) private var dismiss
    @State private var favorite = false
    @State private var playlistID: UUID?
    @State private var create = false
    @State private var name = ""
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 16) {
                        SongArtwork(song: song, size: 80)
                        VStack(alignment: .leading, spacing: 7) {
                            Text(song.title).font(.headline).lineLimit(3)
                            Text(song.artist).font(.subheadline).foregroundStyle(Palette.secondary)
                        }
                    }
                    VStack(spacing: 0) {
                        Toggle(isOn: $favorite) { Label("お気に入りに追加", systemImage: "heart") }.padding(16)
                        Divider().overlay(Palette.raised)
                        Picker("プレイリスト", selection: $playlistID) {
                            Text("ライブラリのみ").tag(UUID?.none)
                            ForEach(library.playlists) { Text($0.name).tag(Optional($0.id)) }
                        }.padding(16)
                    }.background(Palette.surface, in: RoundedRectangle(cornerRadius: 15))
                    Button { name = ""; create = true } label: { Label("新しいプレイリスト", systemImage: "plus.circle").font(.subheadline).frame(minHeight: 44) }
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(Palette.accent)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("音楽として、このiPhoneに保存").font(.subheadline.weight(.semibold))
                            Text("AAC / M4A · 保存後はオフライン再生\n保存が終わるまでアプリを開いてください。").font(.caption).foregroundStyle(Palette.secondary).lineSpacing(4)
                        }
                    }
                    PrimaryButton(title: "曲を保存", symbol: "arrow.down") {
                        music.save(song, favorite: favorite, playlistID: playlistID); dismiss()
                    }.disabled(library.recoveryNeeded)
                    Text("保存する権利・許可のある曲を対象にしてください。")
                        .font(.caption2).foregroundStyle(Palette.secondary)
                }.padding(24)
            }.background(Palette.background).foregroundStyle(Palette.text)
                .navigationTitle("曲を保存").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("閉じる") { dismiss() } } }
                .alert("新しいプレイリスト", isPresented: $create) {
                    TextField("名前", text: $name)
                    Button("キャンセル", role: .cancel) {}
                    Button("作成") { do { playlistID = try library.createPlaylist(name) } catch { library.message = error.localizedDescription } }
                }
        }.appFeedback().presentationDetents([.large]).presentationDragIndicator(.visible)
    }
}

struct SongActionsSheet: View {
    let song: Song
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerStore
    @Environment(\.dismiss) private var dismiss
    @State private var delete = false
    var body: some View {
        NavigationStack {
            List {
                HStack(spacing: 14) {
                    SongArtwork(song: song, size: 64)
                    VStack(alignment: .leading, spacing: 6) { Text(song.title).font(.headline); Text(song.artist).font(.caption).foregroundStyle(Palette.secondary) }
                }.listRowBackground(Color.clear)
                Button { library.toggleFavorite(song.id) } label: {
                    Label(library.song(song.id)?.favorite == true ? "お気に入りから外す" : "お気に入りに追加", systemImage: library.song(song.id)?.favorite == true ? "heart.fill" : "heart")
                }
                Button { player.start(library.songs, at: song); dismiss() } label: { Label("再生", systemImage: "play.fill") }.disabled(!library.isAvailable(song))
                Button { player.enqueue(song); dismiss() } label: { Label("再生キューに追加", systemImage: "text.line.first.and.arrowtriangle.forward") }.disabled(!library.isAvailable(song))
                Section("プレイリストに追加") {
                    if library.playlists.isEmpty { Text("ライブラリの＋からプレイリストを作成できます。").font(.caption).foregroundStyle(Palette.secondary) }
                    ForEach(library.playlists) { playlist in
                        Button {
                            do { try library.add(song.id, to: playlist.id); dismiss() } catch { library.message = error.localizedDescription }
                        } label: { Label(playlist.name, systemImage: playlist.songIDs.contains(song.id) ? "checkmark.circle.fill" : "plus.circle") }
                    }
                }
                if let url = library.file(song.fileName), library.isAvailable(song) {
                    ShareLink(item: url) { Label("音声ファイルを共有", systemImage: "square.and.arrow.up") }
                }
                Section {
                    Button(role: .destructive) { delete = true } label: { Label("ライブラリから削除", systemImage: "trash") }
                }
            }.scrollContentBackground(.hidden).background(Palette.background).tint(Palette.text)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("閉じる") { dismiss() } } }
                .confirmationDialog("このiPhoneから曲を削除しますか？プレイリストからも外れます。検索から再保存できます。", isPresented: $delete, titleVisibility: .visible) {
                    Button("曲とファイルを削除", role: .destructive) {
                        do { try library.delete(song); player.remove(song.id); dismiss() } catch { library.message = error.localizedDescription }
                    }
                }
        }.appFeedback().presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
}

struct DownloadsView: View {
    @EnvironmentObject private var music: MusicService
    @EnvironmentObject private var player: PlayerStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                if music.jobs.isEmpty { EmptyPanel(symbol: "arrow.down.circle", title: "保存状況はここで確認", detail: "検索から曲を選んで保存できます。") }
                LazyVStack(spacing: 16) {
                    ForEach(music.jobs) { job in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 12) {
                                SongArtwork(song: job.song, size: 48)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(job.song.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                                    Text(job.error ?? job.phase).font(.caption).foregroundStyle(job.error == nil ? Palette.secondary : Palette.accent)
                                }
                                Spacer(minLength: 0)
                            }
                            if let _ = job.error {
                                HStack {
                                    Button("再試行") { music.retry(job.id) }.frame(minHeight: 44)
                                    Spacer()
                                    Button("閉じる") { music.dismiss(job.id) }.frame(minHeight: 44)
                                }.font(.subheadline.weight(.semibold))
                            } else if job.finished {
                                HStack {
                                    Button { player.start([job.song], at: job.song); dismiss() } label: { Label("再生", systemImage: "play.fill") }.frame(minHeight: 44)
                                    Spacer()
                                    IconButton(symbol: "xmark", label: "完了した保存を一覧から外す", size: 16) { music.dismiss(job.id) }
                                }
                            } else {
                                if job.fraction > 0 { ProgressView(value: job.fraction).tint(Palette.accent) } else { ProgressView().tint(Palette.accent) }
                                HStack {
                                    Text(job.fraction > 0 ? "\(Int(job.fraction * 100))%" : "処理中").font(.caption).foregroundStyle(Palette.secondary)
                                    Spacer()
                                    Button("キャンセル") { music.cancel(job.id) }.font(.caption).frame(minHeight: 44)
                                }
                            }
                        }.padding(16).background(Palette.surface, in: RoundedRectangle(cornerRadius: 15))
                    }
                }.padding(20)
            }.background(Palette.background).foregroundStyle(Palette.text)
                .navigationTitle("保存の状況").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("閉じる") { dismiss() } } }
        }.appFeedback().presentationDragIndicator(.visible)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("保存した曲", value: "\(library.songs.count)曲")
                    LabeledContent("曲の容量", value: ByteCountFormatter.string(fromByteCount: library.totalBytes, countStyle: .file))
                    Button { importing = true } label: { Label("音声ファイルを読み込む", systemImage: "folder.badge.plus") }
                } header: { Text("このiPhoneのライブラリ") }
                Section("バックアップ") {
                    Text("「ファイル」アプリ → このiPhone内 → UTube Music → UTubeMusic をフォルダーごとコピーすると、曲とプレイリストを保管できます。アプリを削除する前にバックアップしてください。")
                        .font(.subheadline).foregroundStyle(Palette.secondary)
                    Text("library.json が曲とプレイリストの一覧です。library.previous.json は直前の一覧です。読み込みエラー時はアプリを終了し、コピーを保管してから有効な一覧を library.json に戻してください。")
                        .font(.caption).foregroundStyle(Palette.secondary)
                }
                Section("SideStoreでの期限更新") {
                    Text("Wi-Fiに接続 → LocalDevVPNをオン → SideStoreのMy AppsでUTube MusicとSideStoreを更新。通常7日の期限が切れる前に確認してください。更新に料金はかかりません。")
                        .font(.subheadline).foregroundStyle(Palette.secondary)
                }
                Section {
                    LabeledContent("バージョン", value: "0.1.0 開発版")
                    Text("個人用の音楽ライブラリ。曲の取得はYouTubeの仕様や制限により失敗する場合があります。")
                        .font(.caption).foregroundStyle(Palette.secondary)
                    Text("Python / yt-dlp / yt-dlp-ejs / certifi / yt-dlp-apple-webkit-jsi を使用。ライセンスはアプリ内の同梱ファイル ThirdPartyNotices を参照。")
                        .font(.caption).foregroundStyle(Palette.secondary)
                    if let notice = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt") {
                        ShareLink("ライセンスを開く・共有", item: notice)
                    }
                }
            }.scrollContentBackground(.hidden).background(Palette.background)
                .navigationTitle("設定").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("閉じる") { dismiss() } } }
                .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
                    switch result {
                    case .success(let urls):
                        Task {
                            var count = 0
                            var failures: [String] = []
                            for url in urls {
                                do { try await library.importAudio(url); count += 1 }
                                catch { failures.append(url.lastPathComponent + ": " + error.localizedDescription) }
                            }
                            dismiss()
                            library.message = "\(count)曲を読み込みました。" + (failures.isEmpty ? "" : "\n" + failures.joined(separator: "\n"))
                        }
                    case .failure(let error): library.message = error.localizedDescription
                    }
                }
        }.appFeedback()
    }
}
