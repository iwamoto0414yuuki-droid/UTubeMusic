import Foundation

struct CatalogItem: Identifiable, Decodable {
    let id: String
    let kind: String
    let title: String
    let subtitle: String
    let thumbnail: String?
    var kindLabel: String { kind == "album" ? "アルバム" : "プレイリスト" }
    static func link(_ value: String) -> CatalogItem? {
        let value = value.contains("://") ? value : "https://" + value
        guard let url = URLComponents(string: value), url.scheme == "https", url.user == nil, url.password == nil,
              ["music.youtube.com", "youtube.com", "www.youtube.com", "m.youtube.com"].contains(url.host ?? "") else { return nil }
        let id: String
        if url.path.hasPrefix("/browse/MPRE") { id = String(url.path.dropFirst(8)) }
        else if url.path == "/playlist", let list = url.queryItems?.first(where: { $0.name == "list" })?.value { id = list }
        else { return nil }
        guard id.range(of: "^(MPRE|PL|OLAK|RD)[A-Za-z0-9_-]{1,196}$", options: .regularExpression) != nil else { return nil }
        return CatalogItem(id: id, kind: id.hasPrefix("MPRE") ? "album" : "playlist", title: "リンクから開く", subtitle: "YouTube Music", thumbnail: nil)
    }
}
struct CatalogSection: Identifiable, Decodable {
    let id: String
    let title: String
    let items: [CatalogItem]
}

@MainActor
final class CatalogStore: ObservableObject {
    @Published private(set) var sections: [CatalogSection] = []
    @Published private(set) var items: [CatalogItem] = []
    @Published private(set) var songs: [Song] = []
    @Published private(set) var collection: CatalogItem?
    @Published private(set) var unavailable = 0
    @Published private(set) var loading = false
    @Published private(set) var loadingMore = false
    @Published private(set) var loaded = false
    @Published private(set) var error: String?
    @Published private(set) var moreError: String?
    @Published private(set) var hasMore = false
    private var generation = UUID()
    private var offset = 0
    private var query = ""
    private var kind = "playlists"
    private let request: ([String: String]) async throws -> EngineResponse
    init(request: @escaping ([String: String]) async throws -> EngineResponse = { try await PythonService.shared.request($0) }) { self.request = request }
    func home() async {
        guard !loading else { return }
        loading = true; error = nil
        do { sections = try await request(["op": "home"]).sections ?? [] }
        catch { self.error = error.localizedDescription }
        loaded = true; loading = false
    }
    func open(_ item: CatalogItem) async {
        guard !loading else { return }
        loading = true; error = nil
        do {
            let response = try await request(["op": "collection", "id": item.id])
            songs = (response.songs ?? []).map(\.song); collection = response.collection ?? item
            unavailable = response.unavailable ?? 0
        } catch { self.error = error.localizedDescription }
        loaded = true; loading = false
    }
    func search(_ query: String, kind: String) async {
        let token = UUID(); generation = token
        self.query = query; self.kind = kind; offset = 0
        items = []; error = nil; moreError = nil; hasMore = false; loadingMore = false
        loading = !query.isEmpty
        guard loading else { return }
        do {
            let response = try await request(["op": "catalog_search", "query": query, "kind": kind, "offset": "0"])
            guard generation == token else { return }
            apply(response)
        } catch {
            guard generation == token else { return }
            self.error = error.localizedDescription
        }
        loading = false
    }
    func loadMore() async {
        guard hasMore, !loading, !loadingMore else { return }
        let token = generation; loadingMore = true; moreError = nil
        do {
            let response = try await request(["op": "catalog_search", "query": query, "kind": kind, "offset": String(offset)])
            guard generation == token else { return }
            apply(response)
        } catch {
            guard generation == token else { return }
            moreError = error.localizedDescription
        }
        loadingMore = false
    }
    private func apply(_ response: EngineResponse) {
        var seen = Set(items.map(\.id))
        items.append(contentsOf: (response.items ?? []).filter { seen.insert($0.id).inserted })
        let next = response.next_offset ?? offset
        hasMore = response.has_more == true && next > offset; offset = next
    }
}
