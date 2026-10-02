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
    @Environment(AppSettings.self) private var settings
    @State private var previewReplayToken = 0
    @State private var previewPageEffectVisitID = UUID()
    @State private var previewPageEffectVisit: PageEffectVisit?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Text effects").font(.caption).foregroundStyle(.secondary)
                    TextEffectPicker(selection: bind(\.ink))
                    previewRow
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                List {
                    pageTurnSection
                    pageEffectsSection
                    defaultsSection
                }
                .listStyle(.insetGrouped)
            }
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
                        pageEffectVisitID: model.environment.pageEffect.isAnimated
                            ? previewPageEffectVisitID : nil,
                        onPaperReady: { pageIdentity, renderToken, visitID in
                            previewPaperReady(
                                pageIdentity: pageIdentity,
                                renderToken: renderToken,
                                visitID: visitID
                            )
                        }
                    )
                    if model.environment.pageEffect.isAnimated, !reduceMotion,
                       let visit = previewPageEffectVisit,
                       visit.startedAt != nil {
                        PageEffectOverlayView(
                            effect: model.environment.pageEffect,
                            visit: visit,
                            seed: StableHash.hash(
                                "\(model.book.id)|preview|\(model.currentPageIndex)|\(model.environment.pageEffect.rawValue)"
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
                Text(model.environment.pageEffect.title)
                    .font(.caption).foregroundStyle(.secondary)
                Text(model.environment.ink == .enchanted ? "Enchanted Ink · 3–4 seconds" : "Instant text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.environment.pageEffect.isAnimated {
                    Button("Replay page effect") { resetPreviewPageEffects() }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("replay-page-effect")
                        .disabled(reduceMotion)
                }
                if model.environment.ink == .enchanted {
                    Button("Replay ink") { previewReplayToken += 1 }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("reader.replayInk")
                        .disabled(reduceMotion)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .onChange(of: model.currentPageIndex) { _, _ in resetPreviewPageEffects() }
        .onChange(of: model.environment.pageEffect) { _, _ in resetPreviewPageEffects() }
    }

    private var previewSize: CGSize {
        let width: CGFloat = 104
        return CGSize(width: width, height: width * CGFloat(model.pageAspectRatio))
    }

    // MARK: - Effects

    private var pageTurnSection: some View {
        Section {
            PageTurnPicker(selection: Binding(
                get: { settings.pageTurnStyle },
                set: { settings.pageTurnStyle = $0 }
            ))
        } header: {
            Text("Page turn")
        } footer: {
            if reduceMotion { Text("Reduce Motion is on, so pages slide.") }
        }
    }

    private var pageEffectsSection: some View {
        Section("Page effects") {
            if reduceMotion { Text("Reduce Motion is on. Page animations are disabled.").font(.caption) }
            PageEffectPicker(selection: bind(\.pageEffect))
        }
    }

    private func resetPreviewPageEffects() {
        previewPageEffectVisit = nil
        previewPageEffectVisitID = UUID()
    }

    private func previewPaperReady(pageIdentity: String, renderToken: String, visitID: UUID) {
        guard model.environment.pageEffect.isAnimated,
              visitID == previewPageEffectVisitID else { return }
        var visit = previewPageEffectVisit ?? PageEffectVisit(
            unit: 0, visitID: visitID,
            pageRenderTokens: [pageIdentity: renderToken]
        )
        visit.setVisibleFraction(1, at: Date())
        guard visit.paperReady(
            pageIdentity: pageIdentity, renderToken: renderToken,
            visitID: visitID, at: Date()
        ) else { return }
        previewPageEffectVisit = visit
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
