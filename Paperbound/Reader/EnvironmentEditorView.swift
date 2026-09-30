//
//  EnvironmentEditorView.swift
//  Paperbound
//
//  Reading controls for text effects and their preview.
//

import SwiftUI

struct EnvironmentEditorView: View {

    let model: ReaderViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var previewReplayToken = 0
    @State private var previewFootstepReplayToken = 0
    @State private var previewFootstepVisitID = UUID()
    @State private var previewFootstepVisit: FootstepVisit?

    var body: some View {
        NavigationStack {
            List {
                inkSection
                pageEffectsSection
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

    private var previewRow: some View {
        HStack(alignment: .center, spacing: 18) {
            if let provider = model.provider {
                ZStack(alignment: .topLeading) {
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
                        ),
                        pageIdentity: "\(model.book.id.uuidString)|\(model.engine?.stablePageID(for: model.currentLocation) ?? "pdf:\(model.currentPageIndex)")",
                        isPreview: true,
                        replayToken: previewReplayToken,
                        footstepVisitID: model.environment.footstepsEnabled
                            ? previewFootstepVisitID : nil,
                        onPaperReady: { pageIdentity, renderToken, visitID in
                            previewPaperReady(
                                pageIdentity: pageIdentity,
                                renderToken: renderToken,
                                visitID: visitID
                            )
                        }
                    )
                    if model.environment.footstepsEnabled,
                       let visit = previewFootstepVisit,
                       visit.startedAt != nil {
                        FootstepOverlayView(
                            visit: visit,
                            seed: StableHash.hash(
                                "\(model.book.id)|preview|\(model.currentPageIndex)|\(previewFootstepReplayToken)"
                            ),
                            surfaces: [CGRect(origin: .zero, size: previewSize)],
                            reservedRegions: [],
                            size: previewSize,
                            isDarkPaper: model.environment.invertsInk,
                            isPaused: false,
                            artworkScale: 0.3
                        )
                        .id(visit.visitID)
                    }
                }
                .frame(width: previewSize.width, height: previewSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Preview")
                    .font(.headline)
                Text(model.environment.ink == .enchanted ? "Enchanted Ink" : "Instant text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.environment.ink == .enchanted {
                    Button("Replay effect") { previewReplayToken += 1 }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("reader.replayInk")
                        .disabled(reduceMotion)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .onChange(of: model.currentPageIndex) { _, _ in resetPreviewFootsteps() }
        .onChange(of: model.environment.footstepsEnabled) { _, _ in resetPreviewFootsteps() }
    }

    private var previewSize: CGSize {
        let width: CGFloat = 104
        return CGSize(width: width, height: width * CGFloat(model.pageAspectRatio))
    }

    // MARK: - Effects

    private var inkSection: some View {
        Section {
            TextEffectPicker(selection: bind(\.ink))
            previewRow
        } header: {
            Text("Text effects")
        } footer: {
            Text(reduceMotion && model.environment.ink == .enchanted
                ? "Reduce Motion is on. Ink animation is paused and the finished page is shown."
                : model.environment.ink == .enchanted
                    ? "Ink bleeds into blank paper, gradually filling letters and illustrations over 3–4 seconds. The full page plays after you close settings."
                    : "Printed content appears immediately when a page turns. The PDF’s original colors are preserved.")
        }
    }

    private var pageEffectsSection: some View {
        Section("Page effects") {
            Toggle("Footsteps", isOn: bind(\.footstepsEnabled))
            if model.environment.footstepsEnabled {
                Button("Replay footsteps") {
                    previewFootstepReplayToken += 1
                    resetPreviewFootsteps()
                }
                Text("Three trails of small ink shoeprints wander across the visible paper and may cross between pages on Duo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func resetPreviewFootsteps() {
        previewFootstepVisit = nil
        previewFootstepVisitID = UUID()
    }

    private func previewPaperReady(pageIdentity: String, renderToken: String, visitID: UUID) {
        guard model.environment.footstepsEnabled,
              visitID == previewFootstepVisitID else { return }
        var visit = previewFootstepVisit ?? FootstepVisit(
            unit: 0, visitID: visitID,
            pageRenderTokens: [pageIdentity: renderToken]
        )
        visit.setVisibleFraction(1, at: Date())
        guard visit.paperReady(
            pageIdentity: pageIdentity, renderToken: renderToken,
            visitID: visitID, at: Date()
        ) else { return }
        previewFootstepVisit = visit
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
            Text("Each book remembers its own reading settings. Your default applies to new books.")
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
