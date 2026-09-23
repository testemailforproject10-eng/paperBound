//
//  ContentsPanelView.swift
//  Paperbound
//
//  The document's own table of contents, when it has one.
//

import SwiftUI

struct ContentsPanelView: View {

    let model: ReaderViewModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.outline.isEmpty {
                    ContentUnavailableView {
                        Label("No contents", systemImage: "list.bullet.rectangle")
                    } description: {
                        Text("This PDF does not carry an outline. Use search or the page slider to move around.")
                    }
                } else {
                    List(model.outline) { item in
                        Button {
                            model.go(to: item.location)
                            dismiss()
                        } label: {
                            HStack(spacing: 8) {
                                Text(item.title)
                                    .font(item.depth == 0 ? .callout.weight(.semibold) : .callout)
                                    .lineLimit(2)
                                Spacer(minLength: 8)
                                Text("\((item.location.pdfPageIndex ?? 0) + 1)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.leading, CGFloat(item.depth) * 16)
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Contents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct BookmarksPanelView: View {

    let model: ReaderViewModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.book.bookmarks.isEmpty {
                    ContentUnavailableView {
                        Label("No bookmarks", systemImage: "bookmark")
                    } description: {
                        Text("Tap the bookmark button while reading to save your place.")
                    }
                } else {
                    List {
                        ForEach(model.book.sortedBookmarks) { bookmark in
                            Button {
                                model.go(to: bookmark.location)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(bookmark.label)
                                        .font(.callout)
                                    Text(bookmark.createdAt, format: .dateTime.day().month().year().hour().minute())
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { offsets in
                            let sorted = model.book.sortedBookmarks
                            for index in offsets where sorted.indices.contains(index) {
                                model.removeBookmark(sorted[index])
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Bookmarks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
