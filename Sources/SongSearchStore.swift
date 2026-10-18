import Foundation

/// Each screen owns its search, so opening a discovery mix cannot replace search-tab results.
@MainActor
final class SongSearchStore: ObservableObject {
    @Published private(set) var results: [Song] = []
    @Published private(set) var searching = false
    @Published private(set) var loadingMore = false
    @Published private(set) var error: String?
    @Published private(set) var moreError: String?
    @Published private(set) var hasMore = false
    private var query = ""
    private var offset = 0
    private var generation = UUID()
    private let request: ([String: String]) async throws -> EngineResponse

    init(request: @escaping ([String: String]) async throws -> EngineResponse = { try await PythonService.shared.request($0) }) {
        self.request = request
    }
    func search(_ value: String) async {
        let token = UUID(); generation = token
        query = value.trimmingCharacters(in: .whitespacesAndNewlines)
        results = []; error = nil; moreError = nil; offset = 0; hasMore = false; loadingMore = false
        searching = !query.isEmpty
        guard searching else { return }
        do {
            let response = try await request(["op": "search", "query": query, "offset": "0"])
            guard generation == token else { return }
            apply(response)
        } catch {
            guard generation == token else { return }
            self.error = error.localizedDescription
        }
        searching = false
    }
    func loadMore() async {
        guard hasMore, !searching, !loadingMore else { return }
        let token = generation
        loadingMore = true; moreError = nil
        do {
            let response = try await request(["op": "search", "query": query, "offset": String(offset)])
            guard generation == token else { return }
            apply(response)
        } catch {
            guard generation == token else { return }
            moreError = error.localizedDescription
        }
        loadingMore = false
    }
    private func apply(_ response: EngineResponse) {
        var seen = Set(results.map(\.id))
        results.append(contentsOf: (response.songs ?? []).map(\.song).filter { seen.insert($0.id).inserted })
        let next = response.next_offset ?? offset
        hasMore = response.has_more == true && next > offset
        offset = next
    }
}
