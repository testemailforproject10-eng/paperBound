//
//  SettingsView.swift
//  Paperbound
//
//  App-wide preferences: the default reading environment, reading behaviour,
//  and what the library folder is holding.
//

import SwiftData
import SwiftUI

struct SettingsView: View {

    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryEnvironment.self) private var library

    @Query private var books: [Book]

    @State private var storageBytes: Int64 = 0

    var body: some View {
        List {
            textEffectsSection
            pageEffectsSection
            pageTurnSection
            readingSection
            speechSection
            storageSection
            formatsSection
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task { storageBytes = measureStorage() }
    }

    // MARK: - Default effects

    private var textEffectsSection: some View {
        Section {
            TextEffectPicker(selection: environmentBinding(\.ink))
        } header: {
            Text("Text effects")
        } footer: {
            Text("Default effects for new books. Each book can have its own reading settings.")
        }
    }

    private var pageEffectsSection: some View {
        Section("Page effects") {
            PageEffectPicker(selection: environmentBinding(\.pageEffect))
        }
    }

    private var pageTurnSection: some View {
        Section("Page turn") {
            PageTurnPicker(selection: Binding(
                get: { settings.pageTurnStyle },
                set: { settings.pageTurnStyle = $0 }
            ))
        }
    }

    // MARK: - Reading

    private var readingSection: some View {
        Section("Reading") {
            Toggle("Keep the screen awake while reading", isOn: Binding(
                get: { settings.keepScreenAwake },
                set: { settings.keepScreenAwake = $0 }
            ))
        }
    }

    private var speechSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Speaking rate")
                    Spacer()
                    Text("\(Int((settings.speechRate * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { settings.speechRate },
                        set: { settings.speechRate = $0 }
                    ),
                    in: 0...1
                )
            }
        } header: {
            Text("Read aloud")
        } footer: {
            Text("Speech uses the document's own text layer, so it works in both Physical and Pristine modes.")
        }
    }

    // MARK: - Storage

    private var storageSection: some View {
        Section {
            LabeledContent("Books", value: "\(books.count)")
            LabeledContent("Imported files", value: ByteCountFormatter.string(fromByteCount: storageBytes, countStyle: .file))
            Button {
                library.store.removeOrphanedFiles(knownBooks: books)
                storageBytes = measureStorage()
            } label: {
                Label("Clean up unused files", systemImage: "trash")
            }
        } header: {
            Text("Storage")
        } footer: {
            Text("Imported copies live in the app's own folder. They are read, never written to: removing every book would leave each original file exactly as it was imported.")
        }
    }

    private var formatsSection: some View {
        Section {
            LabeledContent("PDF", value: "Supported")
            LabeledContent("EPUB", value: "Not yet")
        } header: {
            Text("Formats")
        } footer: {
            Text("EPUB arrives with a reflowable engine of its own. DRM-protected purchases from other stores cannot be imported.")
        }
    }

    // MARK: - Helpers

    private func environmentBinding<Value>(
        _ keyPath: WritableKeyPath<ReadingEnvironment, Value>
    ) -> Binding<Value> {
        Binding(
            get: { settings.defaultEnvironment[keyPath: keyPath] },
            set: { newValue in
                var next = settings.defaultEnvironment
                next[keyPath: keyPath] = newValue
                if next.id.hasPrefix("preset.") || next.id.hasPrefix("theme.") {
                    next.id = "custom.\(UUID().uuidString.prefix(8))"
                    next.name = "Custom"
                }
                settings.defaultEnvironment = next
            }
        )
    }

    private func measureStorage() -> Int64 {
        let directory = library.store.booksDirectory
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }
}
