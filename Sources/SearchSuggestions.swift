import SwiftUI

struct SearchSuggestions: View {
    let query: String
    let select: (String) -> Void
    @State private var values: [String] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(values, id: \.self) { value in
                Button { select(value) } label: {
                    Label(value, systemImage: "magnifyingglass").font(.subheadline)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.buttonStyle(.plain)
            }
        }.foregroundStyle(Palette.text)
            .task(id: query) {
                values = []
                let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, !text.contains("://") else { return }
                do {
                    try await Task.sleep(nanoseconds: 400_000_000)
                    let response = try await PythonService.shared.request(["op": "suggestions", "query": text])
                    try Task.checkCancellation()
                    var seen = Set<String>()
                    values = (response.suggestions ?? []).filter { seen.insert($0).inserted }
                } catch { }
            }
    }
}
