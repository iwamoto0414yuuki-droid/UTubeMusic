import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerStore
    @State private var filter = 0
    @State private var text = ""
    @State private var newPlaylist = false
    @State private var name = ""
    @State private var selected: Song?
    init(initialFilter: Int = 0) { _filter = State(initialValue: initialFilter) }
    private var visibleSongs: [Song] {
        let songs = filter == 1 ? library.favorites : filter == 3 ? library.songs.filter(library.isAvailable) : library.songs
        return text.isEmpty ? songs : songs.filter { $0.title.localizedCaseInsensitiveContains(text) || $0.artist.localizedCaseInsensitiveContains(text) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text("ライブラリ").font(.largeTitle.bold())
                    Spacer()
                    IconButton(symbol: "plus", label: "プレイリストを作成") { name = ""; newPlaylist = true }
                }.padding(.top, 12)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        chip("すべて", value: 0); chip("お気に入り", value: 1)
                        chip("プレイリスト", value: 2); chip("ダウンロード済み", value: 3)
                    }
                }
                if filter != 2 {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondary)
                        TextField("保存した曲を検索", text: $text).font(.subheadline).autocorrectionDisabled()
                    }.padding(14).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
                }
                if filter != 3 { AddSongsLink(destination: filter == 1 ? .favorites : .library) }
                if filter == 3 {
                    Text("このiPhoneに音声がある曲だけを表示します。YouTubeから保存した曲は、メニューの「ダウンロードだけ削除」で、お気に入り・プレイリストに残したままオンライン再生に切り替えられます。")
                        .font(.caption).foregroundStyle(Palette.secondary).lineSpacing(3)
                }
                if filter == 0 && text.isEmpty || filter == 2 {
                    NavigationLink { CollectionView(favorites: true) } label: {
                        HStack(spacing: 14) {
                            PlaylistArtwork(name: "お気に入り", favorite: true, size: 62)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("お気に入りの曲").font(.headline).foregroundStyle(Palette.text)
                                Text("\(library.favorites.count)曲").font(.caption).foregroundStyle(Palette.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.secondary)
                        }
                    }.buttonStyle(.plain)
                    ForEach(library.playlists) { playlist in
                        NavigationLink { PlaylistDetailView(playlistID: playlist.id) } label: {
                            HStack(spacing: 14) {
                                PlaylistArtwork(name: playlist.name, size: 62)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(playlist.name).font(.headline).foregroundStyle(Palette.text)
                                    Text("プレイリスト · \(playlist.songIDs.count)曲").font(.caption).foregroundStyle(Palette.secondary)
                                }
                                Spacer()
                            }
                        }.buttonStyle(.plain)
                    }
                    if filter == 2 && library.playlists.isEmpty {
                        EmptyPanel(symbol: "rectangle.stack.badge.plus", title: "好きな曲を、ひとまとめに。", detail: "右上の＋からプレイリストを作成できます。")
                    }
                }
                if filter != 2 {
                    HStack {
                        Text(filter == 1 ? "お気に入りの曲" : filter == 3 ? "ダウンロード済みの曲" : "保存した曲").font(.headline)
                        Spacer()
                        Text("\(visibleSongs.count)曲").font(.caption).foregroundStyle(Palette.secondary)
                    }
                    if visibleSongs.isEmpty {
                        EmptyPanel(symbol: "music.note.list", title: filter == 3 ? "ダウンロード済みの曲はありません" : filter == 1 ? "お気に入りを集めよう" : "あなたの音楽は、ここに。", detail: text.isEmpty ? (filter == 3 ? "曲のメニューからオフライン用にダウンロードできます。" : "検索から曲を保存すると、\nここからいつでも聴けます。") : "検索条件に合う曲がありません。")
                    } else {
                        LazyVStack(spacing: 3) {
                            ForEach(visibleSongs) { song in
                                SongRow(song: song, subtitle: library.isPlayable(song) ? song.artist + (library.isAvailable(song) ? " · ダウンロード済み" : " · オンライン") : "ファイルが見つかりません・再保存してください") {
                                    player.start(visibleSongs, at: song)
                                } more: { selected = song }
                            }
                        }
                    }
                }
            }.padding(.horizontal, 20).padding(.bottom, 24)
        }.foregroundStyle(Palette.text).scrollIndicators(.hidden)
            .sheet(item: $selected) { SongActionsSheet(song: $0) }
            .alert("新しいプレイリスト", isPresented: $newPlaylist) {
                TextField("プレイリスト名", text: $name)
                Button("キャンセル", role: .cancel) {}
                Button("作成") {
                    do { try library.createPlaylist(name) } catch { library.message = error.localizedDescription }
                }
            }
    }
    private func chip(_ title: String, value: Int) -> some View {
        Button { filter = value } label: {
            Text(title).font(.system(size: 13, weight: .semibold)).padding(.horizontal, 17).frame(minHeight: 44)
                .background(filter == value ? Palette.text : Palette.raised, in: Capsule())
                .foregroundStyle(filter == value ? Color.black : Palette.text)
        }.buttonStyle(.plain).accessibilityAddTraits(filter == value ? .isSelected : [])
    }
}

struct CollectionView: View {
    var favorites = false
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerStore
    @State private var selected: Song?
    private var songs: [Song] { favorites ? library.favorites : library.songs }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PlaylistArtwork(name: "お気に入り", favorite: favorites, size: 210).frame(maxWidth: .infinity).padding(.vertical, 20)
                Text(favorites ? "お気に入りの曲" : "保存した曲").font(.largeTitle.bold())
                Text("\(songs.count)曲 · " + (songs.allSatisfy(library.isAvailable) ? "オフラインで再生" : "オンライン曲は通信して再生")).font(.caption).foregroundStyle(Palette.secondary)
                HStack {
                    PrimaryButton(title: "再生", symbol: "play.fill") { if let first = songs.first { player.start(songs, at: first) } }
                    IconButton(symbol: "shuffle", label: "シャッフル再生", color: Palette.accent) { if let song = songs.randomElement() { player.start(songs, at: song, shuffle: true) } }
                }.disabled(songs.isEmpty)
                AddSongsLink(destination: favorites ? .favorites : .library)
                if songs.isEmpty { EmptyPanel(symbol: "heart", title: "好きな曲にハートを。", detail: "「曲を追加」から新しい曲を探せます。") }
                ForEach(songs) { song in SongRow(song: song) { player.start(songs, at: song) } more: { selected = song } }
                if songs.count > 5 { AddSongsLink(destination: favorites ? .favorites : .library) }
            }.padding(20)
        }.background(Palette.background).foregroundStyle(Palette.text)
            .toolbar(.visible, for: .navigationBar).toolbarBackground(Palette.background, for: .navigationBar)
            .sheet(item: $selected) { SongActionsSheet(song: $0) }
    }
}

struct PlaylistDetailView: View {
    let playlistID: UUID
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Song?
    @State private var rename = false
    @State private var delete = false
    @State private var newName = ""
    private var playlist: MusicPlaylist? { library.playlists.first { $0.id == playlistID } }
    private var songs: [Song] { playlist.map(library.songs(in:)) ?? [] }
    var body: some View {
        List {
            if let playlist {
                VStack(alignment: .leading, spacing: 20) {
                    PlaylistArtwork(name: playlist.name, size: 210).frame(maxWidth: .infinity).padding(.vertical, 12)
                    Text(playlist.name).font(.largeTitle.bold())
                    Text("\(songs.count)曲 · " + Song.clock(songs.reduce(0) { $0 + $1.duration }))
                        .font(.caption).foregroundStyle(Palette.secondary)
                    HStack {
                        PrimaryButton(title: "再生", symbol: "play.fill") { if let song = songs.first { player.start(songs, at: song) } }
                        IconButton(symbol: "shuffle", label: "シャッフル再生", color: Palette.accent) { if let song = songs.randomElement() { player.start(songs, at: song, shuffle: true) } }
                    }.disabled(songs.isEmpty)
                    AddSongsLink(destination: .playlist(playlistID))
                }.listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 20, trailing: 20)).listRowBackground(Color.clear).listRowSeparator(.hidden)
                if songs.isEmpty {
                    EmptyPanel(symbol: "music.note", title: "このプレイリストに曲を。", detail: "「曲を追加」から検索・保存した曲の追加ができます。")
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                ForEach(songs) { song in
                    SongRow(song: song) { player.start(songs, at: song) } more: { selected = song }
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                        .swipeActions {
                            Button("外す", role: .destructive) {
                                do { try library.remove(song.id, from: playlistID) } catch { library.message = error.localizedDescription }
                            }
                        }
                }.onMove { source, destination in
                    do { try library.move(in: playlistID, from: source, to: destination) } catch { library.message = error.localizedDescription }
                }
                if songs.count > 5 {
                    AddSongsLink(destination: .playlist(playlistID))
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
            }
        }.listStyle(.plain).scrollContentBackground(.hidden).background(Palette.background).foregroundStyle(Palette.text)
            .toolbar(.visible, for: .navigationBar).toolbarBackground(Palette.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("名前を変更", systemImage: "pencil") { newName = playlist?.name ?? ""; rename = true }
                        Button("プレイリストを削除", systemImage: "trash", role: .destructive) { delete = true }
                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                }
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
            .sheet(item: $selected) { SongActionsSheet(song: $0) }
            .alert("プレイリスト名", isPresented: $rename) {
                TextField("名前", text: $newName)
                Button("キャンセル", role: .cancel) {}
                Button("保存") { do { try library.renamePlaylist(playlistID, name: newName) } catch { library.message = error.localizedDescription } }
            }
            .confirmationDialog("プレイリストを削除しますか？保存した曲はライブラリに残ります。", isPresented: $delete, titleVisibility: .visible) {
                Button("プレイリストを削除", role: .destructive) {
                    do { try library.deletePlaylist(playlistID); dismiss() } catch { library.message = error.localizedDescription }
                }
            }
    }
}
