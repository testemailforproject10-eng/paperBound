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
            defaultEnvironmentSection
            readingSection
            speechSection
            storageSection
            formatsSection
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task { storageBytes = measureStorage() }
    }

    // MARK: - Default environment

    private var defaultEnvironmentSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(ReadingEnvironment.allPresets) { preset in
                        Button {
                            settings.defaultEnvironment = preset
                        } label: {
                            VStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 5)
                                    // The substrate's colour, so a stone or
                                    // metal default is recognisable here.
                                    .fill(preset.palette.base.swiftUIColor)
                                    .frame(width: 48, height: 64)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 5)
                                            .strokeBorder(
                                                settings.defaultEnvironment.id == preset.id
                                                    ? Color.accentColor
                                                    : Color.black.opacity(0.18),
                                                lineWidth: settings.defaultEnvironment.id == preset.id ? 2.5 : 1
                                            )
                                    )
                                Text(preset.name)
                                    .font(.caption2)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                    .frame(width: 62)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }

            Picker("Paper", selection: environmentBinding(\.material)) {
                ForEach(PaperMaterial.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("Condition", selection: environmentBinding(\.condition)) {
                ForEach(PageCondition.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("Book", selection: environmentBinding(\.presentation)) {
                ForEach(BookPresentation.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("Light", selection: environmentBinding(\.lighting)) {
                ForEach(LightingStyle.allCases) { Text($0.displayName).tag($0) }
            }

            if settings.defaultEnvironment.condition != .pristine {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Intensity")
                        Spacer()
                        Text("\(Int((settings.defaultEnvironment.intensity * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: environmentBinding(\.intensity), in: 0...1)
                }
            }
        } header: {
            Text("Default reading environment")
        } footer: {
            Text("New books open with this. A book that has chosen its own environment keeps it.")
        }
    }

    // MARK: - Reading

    private var readingSection: some View {
        Section("Reading") {
            Picker("Page layout", selection: Binding(
                get: { settings.spreadPreference },
                set: { settings.spreadPreference = $0 }
            )) {
                ForEach(SpreadPreference.allCases) { Text($0.displayName).tag($0) }
            }
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
                if next.id.hasPrefix("preset.") {
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
