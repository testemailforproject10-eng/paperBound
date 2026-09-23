//
//  EnvironmentEditorView.swift
//  Paperbound
//
//  The four dimensions are edited independently — material, condition,
//  presentation, lighting — rather than being bundled into a long list of
//  fixed themes. Presets are just starting points that write into the same
//  four controls.
//

import SwiftUI

struct EnvironmentEditorView: View {

    let model: ReaderViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings

    var body: some View {
        NavigationStack {
            List {
                previewSection
                presetSection
                themedPresetSection
                materialSection
                conditionSection
                marginaliaSection
                presentationSection
                lightingSection
                defaultsSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Reading environment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Preview

    private var previewSection: some View {
        Section {
            HStack(alignment: .center, spacing: 18) {
                if let provider = model.provider {
                    PhysicalPageView(
                        location: model.currentLocation,
                        environment: model.environment,
                        provider: provider,
                        spineShadowScale: model.layout.spineShadowScale,
                        displaySize: previewSize,
                        // A lone preview thumbnail is a single leaf, so it gets
                        // the recto/verso alternation rather than a gutter edge.
                        spine: DeviceLayoutCoordinator.spineEdge(
                            position: 0,
                            of: 1,
                            pageIndex: model.currentPageIndex
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(model.environment.name)
                        .font(.headline)
                    Text(model.environment.conditionSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if model.environment.condition.removesContent {
                        Label("Removes content on screen only", systemImage: "arrow.uturn.backward")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
        } footer: {
            Text("This is the page you are on, drawn with the settings below. The imported file is never modified — switch to Pristine at any time to see the document exactly as it was delivered.")
        }
    }

    private var previewSize: CGSize {
        let width: CGFloat = 104
        return CGSize(width: width, height: width * CGFloat(model.pageAspectRatio))
    }

    // MARK: - Presets

    private var presetSection: some View {
        Section("Presets") {
            presetRow(ReadingEnvironment.presets)
        }
    }

    /// The themed environments get their own row rather than being appended to
    /// the plain ones. They are a different kind of choice — a material, not a
    /// tuning — and burying eleven of them at the end of a six-item scroller is
    /// how they end up unreachable.
    private var themedPresetSection: some View {
        Section {
            presetRow(ReadingEnvironment.themedPresets)
        } header: {
            Text("Themed")
        } footer: {
            Text("Each of these is the same set of controls below at different settings. Change any one of them and this becomes a custom environment — the preset is always one tap away again.")
        }
    }

    private func presetRow(_ presets: [ReadingEnvironment]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(presets) { preset in
                    Button {
                        model.applyPreset(preset)
                    } label: {
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 5)
                                // The substrate's own colour, not the paper
                                // material's: a stone tablet's swatch has to
                                // look like stone or the row is unreadable.
                                .fill(preset.palette.base.swiftUIColor)
                                .frame(width: 54, height: 72)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5)
                                        .strokeBorder(
                                            model.environment.id == preset.id
                                                ? Color.accentColor
                                                : Color.black.opacity(0.18),
                                            lineWidth: model.environment.id == preset.id ? 2.5 : 1
                                        )
                                )
                                .overlay(alignment: .bottomTrailing) {
                                    if preset.condition.removesContent {
                                        Image(systemName: "scissors")
                                            .font(.system(size: 9))
                                            .foregroundStyle(preset.palette.fiber.swiftUIColor)
                                            .padding(4)
                                    }
                                }
                                .overlay(alignment: .topLeading) {
                                    if preset.marginalia.producesAnything {
                                        Image(systemName: "pencil")
                                            .font(.system(size: 9))
                                            .foregroundStyle(preset.palette.fiber.swiftUIColor)
                                            .padding(4)
                                    }
                                }
                            Text(preset.name)
                                .font(.caption2)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .frame(width: 66)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Dimensions

    private var materialSection: some View {
        let substrate = model.environment.substrate
        return Section {
            Picker("Made of", selection: bind(\.substrate)) {
                ForEach(Substrate.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }

            Text(substrate.summary)
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker(substrate == .paper ? "Material" : "Tone", selection: bind(\.material)) {
                ForEach(PaperMaterial.allCases) { material in
                    Text(material.displayName).tag(material)
                }
            }
            .pickerStyle(.segmented)

            // Swatches follow the substrate, so switching to stone repaints the
            // row in stone rather than leaving five paper colours behind.
            HStack(spacing: 8) {
                ForEach(PaperMaterial.allCases) { material in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(substrate.palette(for: material).base.swiftUIColor)
                        .frame(height: 26)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Color.black.opacity(0.15), lineWidth: 1)
                        )
                }
            }
            .listRowSeparator(.hidden)
        } header: {
            Text(substrate == .paper ? "Paper" : "Surface")
        } footer: {
            if substrate != .paper {
                Text("On anything other than paper the five stocks choose a tone rather than a colour, so \"Aged\" means mid-toned \(substrate.displayName.lowercased()).")
            }
        }
    }

    private var marginaliaSection: some View {
        Section {
            Picker("Marks", selection: bind(\.marginalia)) {
                ForEach(MarginaliaStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }

            Text(model.environment.marginalia.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Marks")
        } footer: {
            Text("Annotation is drawn in the margins and never over the words. A book with marks in it carries a wider margin, because that is what makes a book writable.")
        }
    }

    private var conditionSection: some View {
        Section("Condition") {
            Picker("Condition", selection: bind(\.condition)) {
                ForEach(PageCondition.allCases) { condition in
                    Text(condition.displayName).tag(condition)
                }
            }
            .pickerStyle(.segmented)

            Text(model.environment.conditionSummary)
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.environment.condition != .pristine {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Intensity")
                        Spacer()
                        Text("\(Int((model.environment.intensity * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { model.environment.intensity },
                            set: { newValue in
                                var next = model.environment
                                next.intensity = newValue
                                model.environment = next
                            }
                        ),
                        in: 0...1
                    )
                }

                Button {
                    model.rerollWear()
                } label: {
                    Label("New wear pattern for this copy", systemImage: "shuffle")
                }
            }
        }
    }

    private var presentationSection: some View {
        Section("Book") {
            Picker("Presentation", selection: bind(\.presentation)) {
                ForEach(BookPresentation.allCases) { presentation in
                    Text(presentation.displayName).tag(presentation)
                }
            }
            Picker("Page layout", selection: Binding(
                get: { settings.spreadPreference },
                set: { newValue in
                    settings.spreadPreference = newValue
                }
            )) {
                ForEach(SpreadPreference.allCases) { preference in
                    Text(preference.displayName).tag(preference)
                }
            }
            LabeledContent("Current surface") {
                Text(model.layout.mode == .spread ? "Two pages" : "One page")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Posture") {
                // Never claim more than the platform actually told us.
                Text("\(model.layout.posture.displayName) (\(model.layout.postureEvidence))")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private var lightingSection: some View {
        Section("Light") {
            Picker("Lighting", selection: bind(\.lighting)) {
                ForEach(LightingStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
        }
    }

    private var defaultsSection: some View {
        Section {
            Button {
                model.setAsGlobalDefault()
            } label: {
                Label("Use for new books too", systemImage: "square.stack.3d.up")
            }
            Button(role: .destructive) {
                model.resetToGlobalDefault()
            } label: {
                Label("Reset to my default", systemImage: "arrow.counterclockwise")
            }
        } footer: {
            Text("Each book remembers its own environment and its own wear pattern. The default applies to books that have not chosen one.")
        }
    }

    // MARK: - Binding helper

    private func bind<Value>(
        _ keyPath: WritableKeyPath<ReadingEnvironment, Value>
    ) -> Binding<Value> {
        Binding(
            get: { model.environment[keyPath: keyPath] },
            set: { newValue in
                var next = model.environment
                next[keyPath: keyPath] = newValue
                // Editing any dimension means this is no longer a named preset.
                // Both prefixes count: a themed environment that has been
                // altered is no more "Stone tablet" than an altered plain one
                // is still "Soft cream", and leaving the name on it would let
                // the header claim a preset the settings no longer match.
                if next.id.hasPrefix("preset.") || next.id.hasPrefix("theme.") {
                    next.id = "custom.\(UUID().uuidString.prefix(8))"
                    next.name = "Custom"
                }
                model.environment = next
            }
        )
    }
}
