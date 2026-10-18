import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerStore
    @EnvironmentObject private var music: MusicService
    @State private var tab = 0
    @State private var query = ""
    @State private var searchToken = UUID()
    @State private var showPlayer = false
    @State private var showDownloads = false
    @State private var showSettings = false
    @State private var saveSong: Song?
    @State private var menuSong: Song?
    @State private var handledPreview = false

    var body: some View {
        NavigationStack {
            Group {
                switch tab {
                case 1: searchScreen
                case 2: LibraryView()
                default: homeScreen
                }
            }
            .background(Palette.background)
            .toolbar(.hidden, for: .navigationBar)
        }
        .id(tab)
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .sheet(item: $saveSong) { song in SaveSongSheet(song: song) }
        .sheet(item: $menuSong) { song in SongActionsSheet(song: song) }
        .sheet(isPresented: $showDownloads) { DownloadsView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .fullScreenCover(isPresented: $showPlayer) { NowPlayingView() }
        .appFeedback()
        .task {
            #if DEBUG
            // CI uses a silent, generated test file in an isolated simulator container.
            // This route and its sample library are absent from the release app.
            if !handledPreview, ProcessInfo.processInfo.arguments.contains("--preview-player"), let song = library.songs.first {
                handledPreview = true
                player.start(library.songs, at: song)
                showPlayer = true
            }
            #endif
        }
        .onOpenURL { url in
            guard url.scheme == "utubemusic", let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let value = components.queryItems?.first(where: { $0.name == "url" })?.value else { return }
            runSearch(value)
        }
    }
    private var header: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(Palette.accent).frame(width: 34, height: 34)
                Image(systemName: "waveform").font(.system(size: 17, weight: .bold)).foregroundStyle(.black)
            }.accessibilityHidden(true)
            Text("UTube Music").font(.system(size: 22, weight: .bold, design: .rounded)).tracking(-0.7)
            Spacer()
            ZStack(alignment: .topTrailing) {
                IconButton(symbol: "arrow.down.circle", label: "保存の状況") { showDownloads = true }
                if music.jobs.contains(where: { !$0.finished && $0.error == nil }) { Circle().fill(Palette.accent).frame(width: 7, height: 7).padding(7) }
            }
            IconButton(symbol: "gearshape", label: "設定") { showSettings = true }
        }.foregroundStyle(Palette.text).padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 12)
    }
    private var homeScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header.padding(.horizontal, -20)
                VStack(alignment: .leading, spacing: 18) {
                    Text("YOUR MUSIC, YOUR SPACE").font(.system(size: 10, weight: .bold)).tracking(2.4).foregroundStyle(Palette.accent)
                    Text("好きな曲を、\nいつもそばに。").font(.system(size: 32, weight: .bold)).tracking(-1.2).lineSpacing(2)
                    Text("見つけて、保存して、そのまま聴こう。").font(.subheadline).foregroundStyle(Palette.secondary)
                    Button { tab = 1 } label: {
                        Label("曲を探す", systemImage: "magnifyingglass").font(.subheadline.weight(.bold))
                            .padding(.horizontal, 22).padding(.vertical, 14).background(Palette.text, in: Capsule()).foregroundStyle(.black)
                    }.buttonStyle(.plain)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
                    .background {
                        ZStack(alignment: .topTrailing) {
                            LinearGradient(colors: [Color(red: 0.28, green: 0.16, blue: 0.18), Palette.surface], startPoint: .topLeading, endPoint: .bottomTrailing)
                            ForEach(0..<4) { n in
                                Circle().stroke(Palette.accent.opacity(0.12), lineWidth: 1)
                                    .frame(width: CGFloat(80 + n * 44), height: CGFloat(80 + n * 44)).offset(x: 65, y: -35)
                            }
                        }.clipShape(RoundedRectangle(cornerRadius: 22))
                    }
                if !library.songs.isEmpty {
                    SectionTitle(title: "最近保存した曲", caption: "オフラインでも、すぐ再生")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 16) {
                            ForEach(Array(library.songs.prefix(10))) { song in
                                Button { player.start(library.songs, at: song) } label: {
                                    VStack(alignment: .leading, spacing: 9) {
                                        SongArtwork(song: song, size: 146, radius: 12)
                                        Text(song.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                                        Text(song.artist).font(.caption).foregroundStyle(Palette.secondary).lineLimit(1)
                                    }.frame(width: 146, alignment: .leading).foregroundStyle(Palette.text)
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                SectionTitle(title: "今の気分から探す", caption: "気になるジャンルをタップ")
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(Array(["J-POP", "Chill", "Jazz", "ピアノ"].enumerated()), id: \.offset) { index, genre in
                        Button { runSearch(genre) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 16) {
                                    Image(systemName: ["sparkles", "moon.stars", "pianokeys", "music.note"][index]).font(.title3)
                                    Text(genre).font(.headline)
                                }
                                Spacer()
                            }.foregroundStyle(Palette.text).padding(18).frame(maxWidth: .infinity, minHeight: 110)
                                .background([Color(red: 0.36, green: 0.22, blue: 0.26), Color(red: 0.2, green: 0.25, blue: 0.38), Color(red: 0.22, green: 0.31, blue: 0.29), Color(red: 0.31, green: 0.26, blue: 0.19)][index], in: RoundedRectangle(cornerRadius: 15))
                        }.buttonStyle(.plain)
                    }
                }
                if !library.playlists.isEmpty {
                    SectionTitle(title: "あなたのプレイリスト")
                    ForEach(Array(library.playlists.prefix(3))) { playlist in
                        NavigationLink { PlaylistDetailView(playlistID: playlist.id) } label: {
                            HStack(spacing: 14) {
                                PlaylistArtwork(name: playlist.name, size: 58)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(playlist.name).font(.headline).foregroundStyle(Palette.text)
                                    Text("\(playlist.songIDs.count)曲").font(.caption).foregroundStyle(Palette.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(Palette.secondary)
                            }
                        }.buttonStyle(.plain)
                    }
                }
            }.padding(.horizontal, 20).padding(.bottom, 24)
        }.scrollIndicators(.hidden)
    }
    private var searchScreen: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("検索").font(.largeTitle.bold())
                Spacer()
                IconButton(symbol: "arrow.down.circle", label: "保存の状況") { showDownloads = true }
            }.padding(.horizontal, 20).padding(.vertical, 16)
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondary)
                TextField("曲名、アーティスト、YouTubeリンク", text: $query)
                    .font(.subheadline).autocorrectionDisabled().textInputAutocapitalization(.never).submitLabel(.search)
                    .onSubmit { searchToken = UUID() }
                if !query.isEmpty {
                    IconButton(symbol: "xmark.circle.fill", label: "検索をクリア", color: Palette.secondary, size: 17) { query = ""; searchToken = UUID() }
                }
            }.padding(.leading, 15).padding(.trailing, 4).frame(minHeight: 52)
                .background(Palette.raised, in: RoundedRectangle(cornerRadius: 13)).padding(.horizontal, 20)
            HStack {
                Text("YouTubeで曲を検索").font(.caption).foregroundStyle(Palette.secondary)
                Spacer()
                Button("検索") { searchToken = UUID() }.font(.subheadline.bold()).frame(minHeight: 44)
            }.padding(.horizontal, 22)
            ScrollView {
                if music.searching {
                    VStack(spacing: 16) { ProgressView().tint(Palette.accent); Text("曲を探しています…").font(.subheadline).foregroundStyle(Palette.secondary) }.frame(maxWidth: .infinity).padding(.top, 60)
                } else if let error = music.searchError {
                    EmptyPanel(symbol: "wifi.exclamationmark", title: "曲を読み込めませんでした", detail: error)
                    Button("もう一度検索") { searchToken = UUID() }.padding()
                } else if music.results.isEmpty {
                    EmptyPanel(symbol: "music.magnifyingglass", title: query.isEmpty ? "次に好きになる曲を。" : "曲が見つかりませんでした", detail: query.isEmpty ? "曲名やアーティストで検索。\nYouTubeの曲のリンクからも保存できます。" : "別の曲名やアーティストで探してみてください。")
                } else {
                    LazyVStack(spacing: 4) {
                        ForEach(music.results) { song in
                            let existing = library.song(song.id)
                            let available = existing.map(library.isAvailable) ?? false
                            SongRow(song: song, subtitle: song.artist + (song.duration > 0 ? " · " + song.timeLabel : ""), trailing: available ? "checkmark.circle.fill" : "arrow.down.circle") {
                                if let existing, available { player.start([existing], at: existing) }
                                else { saveSong = song }
                            } more: { if let existing, available { menuSong = existing } else { saveSong = song } }
                        }
                    }.padding(.horizontal, 20).padding(.bottom, 20)
                }
            }.scrollDismissesKeyboard(.interactively)
        }.foregroundStyle(Palette.text)
            .task(id: searchToken) { await music.search(query) }
    }
    private var bottomBar: some View {
        VStack(spacing: 0) {
            if let song = player.current {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Button { showPlayer = true } label: {
                            HStack(spacing: 10) {
                                SongArtwork(song: song, size: 42, radius: 6)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(song.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                    Text(song.artist).font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("再生画面を開く：\(song.title)")
                        IconButton(symbol: library.song(song.id)?.favorite == true ? "heart.fill" : "heart", label: "お気に入りを切り替え", color: library.song(song.id)?.favorite == true ? Palette.accent : Palette.text, size: 19) { library.toggleFavorite(song.id) }
                        IconButton(symbol: player.playing ? "pause.fill" : "play.fill", label: player.playing ? "一時停止" : "再生") { player.toggle() }
                    }.padding(.horizontal, 9).padding(.vertical, 7)
                    GeometryReader { geo in
                        Rectangle().fill(Palette.accent).frame(width: geo.size.width * min(1, max(0, player.elapsed / max(1, player.duration))))
                    }.frame(height: 2).background(.white.opacity(0.08))
                }.background(Palette.raised, in: RoundedRectangle(cornerRadius: 11)).clipShape(RoundedRectangle(cornerRadius: 11)).padding(.horizontal, 8).padding(.bottom, 6)
            }
            HStack(spacing: 0) {
                tabButton(0, title: "ホーム", icon: "house", selected: "house.fill")
                tabButton(1, title: "検索", icon: "magnifyingglass", selected: "magnifyingglass")
                tabButton(2, title: "ライブラリ", icon: "square.stack", selected: "square.stack.fill")
            }.padding(.top, 6).padding(.bottom, 2)
        }.foregroundStyle(Palette.text).background(Palette.background.opacity(0.98))
    }
    private func tabButton(_ index: Int, title: String, icon: String, selected: String) -> some View {
        Button { tab = index } label: {
            VStack(spacing: 5) {
                Image(systemName: tab == index ? selected : icon).font(.system(size: 22, weight: tab == index ? .semibold : .regular))
                Text(title).font(.system(size: 10, weight: .semibold))
            }.foregroundStyle(tab == index ? Palette.text : Palette.secondary).frame(maxWidth: .infinity, minHeight: 48)
        }.buttonStyle(.plain).accessibilityAddTraits(tab == index ? .isSelected : [])
    }
    private func runSearch(_ value: String) { query = value; tab = 1; searchToken = UUID() }
}
