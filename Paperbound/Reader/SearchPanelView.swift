//
//  SearchPanelView.swift
//  Paperbound
//
//  Full-text search over the document's real text layer. Available whichever
//  renderer is on screen, because search never runs against pixels.
//

import SwiftUI

struct SearchPanelView: View {

    let model: ReaderViewModel

    @Environment(\.dismiss) private var dismiss
    @FocusState private var queryFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                Divider()
                results
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { queryFocused = true }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search this book", text: Binding(
                get: { model.searchQuery },
                set: { model.searchQuery = $0 }
            ))
            .focused($queryFocused)
            .submitLabel(.search)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .onSubmit { model.runSearch() }

            if !model.searchQuery.isEmpty {
                Button {
                    model.clearSearch()
                    queryFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var results: some View {
        if model.isSearching {
            Spacer()
            ProgressView("Searching \(model.pageCount) pages")
                .font(.footnote)
            Spacer()
        } else if model.searchResults.isEmpty {
            Spacer()
            ContentUnavailableView {
                Label(
                    model.searchQuery.count >= 2 ? "No matches" : "Search this book",
                    systemImage: "text.magnifyingglass"
                )
            } description: {
                Text(
                    model.searchQuery.count >= 2
                        ? "Nothing in this document matches “\(model.searchQuery)”."
                        : "Type at least two characters, then press return."
                )
            }
            Spacer()
        } else {
            List(model.searchResults) { result in
                Button {
                    model.go(to: result.location)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(highlighted(result))
                            .font(.callout)
                            .lineLimit(3)
                        Text("Page \(result.pageLabel)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .safeAreaInset(edge: .top) {
                Text("\(model.searchResults.count) match\(model.searchResults.count == 1 ? "" : "es")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 6)
                    .background(.bar)
            }
        }
    }

    /// Bolds the matched characters inside the snippet.
    private func highlighted(_ result: ReadingSearchResult) -> AttributedString {
        var attributed = AttributedString(result.snippet)
        let characters = Array(result.snippet)
        guard result.matchRange.lowerBound >= 0,
              result.matchRange.upperBound <= characters.count,
              result.matchRange.lowerBound < result.matchRange.upperBound,
              let start = attributed.index(
                attributed.startIndex,
                offsetByCharacters: result.matchRange.lowerBound,
                limitedBy: attributed.endIndex
              ),
              let end = attributed.index(
                attributed.startIndex,
                offsetByCharacters: result.matchRange.upperBound,
                limitedBy: attributed.endIndex
              )
        else { return attributed }

        attributed[start..<end].font = .callout.bold()
        attributed[start..<end].backgroundColor = HighlightColor.butter.color.swiftUIColor
        return attributed
    }
}

private extension AttributedString {
    /// `AttributedString` indexes by character, but only offers `index(_:offsetByCharacters:)`
    /// without a bound; this adds the bounded form the snippet highlighter needs.
    func index(
        _ start: Index,
        offsetByCharacters offset: Int,
        limitedBy limit: Index
    ) -> Index? {
        guard offset >= 0 else { return nil }
        var current = start
        var remaining = offset
        while remaining > 0 {
            guard current < limit else { return nil }
            current = characters.index(after: current)
            remaining -= 1
        }
        return current <= limit ? current : nil
    }
}
