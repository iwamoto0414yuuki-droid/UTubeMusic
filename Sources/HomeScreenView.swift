import SwiftUI

struct HomeScreenView: View {
    let openSearch: (String) -> Void
    let openDownloads: () -> Void
    let openSettings: () -> Void
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerStore
    @EnvironmentObject private var music: MusicService
    @ObservedObject var catalog: CatalogStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 8) {
                    ZStack {
                        Circle().fill(Palette.accent).frame(width: 34, height: 34)
                        Image(systemName: "waveform").font(.system(size: 17, weight: .bold)).foregroundStyle(.black)
                    }.accessibilityHidden(true)
                    Text("UTube Music").font(.system(size: 22, weight: .bold, design: .rounded)).tracking(-0.7)
                    Spacer(minLength: 0)
                    ZStack(alignment: .topTrailing) {
                        IconButton(symbol: "arrow.down.circle", label: "保存の状況", action: openDownloads)
                        if music.jobs.contains(where: { !$0.finished && $0.error == nil }) {
                            Circle().fill(Palette.accent).frame(width: 7, height: 7).padding(7)
                        }
                    }
                    IconButton(symbol: "gearshape", label: "設定", action: openSettings)
                }.padding(.top, 10)
                Text("今日も、好きな音楽を。").font(.system(size: 27, weight: .bold)).tracking(-0.8)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    NavigationLink { CollectionView(favorites: true) } label: {
                        shortcut("お気に入り", symbol: "heart.fill", count: library.favorites.count, favorite: true)
                    }.buttonStyle(.plain)
                    NavigationLink { CollectionView() } label: {
                        shortcut("保存した曲", symbol: "arrow.down", count: library.songs.count)
                    }.buttonStyle(.plain)
                    ForEach(Array(library.playlists.prefix(4))) { playlist in
                        NavigationLink { PlaylistDetailView(playlistID: playlist.id) } label: {
                            shortcut(playlist.name, symbol: "music.note.list", count: playlist.songIDs.count)
                        }.buttonStyle(.plain)
                    }
                }
                if library.songs.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("好きな曲と、出会う場所。").font(.title2.bold())
                        Text("曲名で探しても、アルバムをまるごとでも。\n保存した音楽はオフラインで聴けます。")
                            .font(.subheadline).foregroundStyle(Palette.secondary).lineSpacing(3)
                        Button { openSearch("") } label: {
                            Label("曲・アルバムを探す", systemImage: "magnifyingglass").font(.subheadline.bold()).padding(.vertical, 12)
                        }
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                        .background(LinearGradient(colors: [Palette.accent.opacity(0.18), Palette.surface], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 18))
                }
                if !library.songs.isEmpty {
                    SectionTitle(title: "最近保存した曲", caption: "いつでも、オフラインで")
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
                HStack {
                    SectionTitle(title: "新しい音楽を見つける", caption: "YouTube Musicの公開プレイリスト・アルバム")
                    if catalog.loading { ProgressView().tint(Palette.accent) }
                    else { IconButton(symbol: "arrow.clockwise", label: "おすすめを更新", size: 17) { Task { await catalog.home() } } }
                }
                if let error = catalog.error {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("おすすめを取得できませんでした").font(.subheadline.bold())
                        Text(error).font(.caption).foregroundStyle(Palette.secondary)
                        Button("再読み込み") { Task { await catalog.home() } }.frame(minHeight: 44)
                    }
                }
                ForEach(catalog.sections) { section in CatalogShelf(title: section.title, items: section.items) }
                if !catalog.loading && catalog.sections.isEmpty && catalog.error == nil {
                    Text("公開のおすすめは、地域や取得時点によって表示されないことがあります。検索からプレイリストやアルバムを探せます。")
                        .font(.subheadline).foregroundStyle(Palette.secondary)
                }
                Button { openSearch("") } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "rectangle.stack.badge.plus").font(.title2).foregroundStyle(Palette.accent)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("プレイリスト・アルバムを探す").font(.subheadline.bold())
                            Text("リンクから開いて、まとめて保存も").font(.caption).foregroundStyle(Palette.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption)
                    }.padding(18).background(Palette.surface, in: RoundedRectangle(cornerRadius: 15))
                }.buttonStyle(.plain)
            }.padding(.horizontal, 20).padding(.bottom, 32)
        }.scrollIndicators(.hidden).foregroundStyle(Palette.text).accessibilityIdentifier("home-scroll")
            .task { if !catalog.loaded { await catalog.home() } }
            .refreshable { await catalog.home() }
    }
    private func shortcut(_ title: String, symbol: String, count: Int, favorite: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 20, weight: .semibold)).frame(width: 42, height: 64)
                .background(favorite ? Color.purple.opacity(0.4) : Palette.accent.opacity(0.2))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .bold)).lineLimit(2)
                Text("\(count)曲").font(.caption2).foregroundStyle(Palette.secondary)
            }
            Spacer(minLength: 4)
        }.foregroundStyle(Palette.text).frame(maxWidth: .infinity, minHeight: 64)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 9)).clipShape(RoundedRectangle(cornerRadius: 9))
    }
}
