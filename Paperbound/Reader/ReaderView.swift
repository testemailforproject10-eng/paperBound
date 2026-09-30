//
//  ReaderView.swift
//  Paperbound
//
//  The reading screen. Holds the two renderers, the controls, and the panels.
//

import PDFKit
import SwiftData
import SwiftUI

struct ReaderView: View {

    let book: Book

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryEnvironment.self) private var library

    @State private var model: ReaderViewModel?

    init(book: Book, model: ReaderViewModel? = nil) {
        self.book = book
        self._model = State(initialValue: model)
    }

    var body: some View {
        ZStack {
            if let model {
                loadedReader(model)
            } else {
                Color.black.ignoresSafeArea()
                ProgressView().tint(.white)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(model?.showsControls == false)
        .task {
            guard model == nil else { return }
            let created = ReaderViewModel(
                book: book,
                settings: settings,
                store: library.store,
                context: context
            )
            model = created
            await created.load()
        }
        .onDisappear {
            model?.unload()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    // MARK: - Loaded state

    @ViewBuilder
    private func loadedReader(_ model: ReaderViewModel) -> some View {
        ZStack {
            model.environment.presentation.surroundColor.swiftUIColor
                .ignoresSafeArea()

            Group {
                if let error = model.loadError, model.engine == nil {
                    failureView(error)
                } else if model.isLoading {
                    ProgressView().tint(.white)
                } else {
                    readingSurface(model)
                }
            }
            // The bars inset the reading surface rather than floating over it.
            // Overlaying them clipped the sheet's head and tail — barely visible
            // on a tall phone, obvious on the Duo's short cover screen, where
            // the torn top edge of the page disappeared under the title bar.
            .safeAreaInset(edge: .top, spacing: 0) {
                if model.showsControls {
                    topBar(model).transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if model.showsControls {
                    bottomBar(model).transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }

            // Zero-size, non-interactive: it exists only to give
            // UIHingeInteraction a view to live on. Without it the hinge is
            // never read and posture falls back to display observation.
            HingeObservationView(observer: model.hinge)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-paperbound-demo-hud") {
                LayoutHUDView(model: model)
            }
            #endif
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = settings.keepScreenAwake
            #if DEBUG
            // `-paperbound-demo-panel environment` opens a panel on launch, so
            // the environment picker can be captured without tapping through
            // the controls first. Same rationale as the other demo hooks.
            if let index = ProcessInfo.processInfo.arguments
                .firstIndex(of: "-paperbound-demo-panel"),
               index + 1 < ProcessInfo.processInfo.arguments.count,
               let panel = ReaderPanel(rawValue: ProcessInfo.processInfo.arguments[index + 1]) {
                model.activePanel = panel
            }
            #endif
        }
        .sheet(item: Binding(
            get: { model.activePanel },
            set: { model.activePanel = $0 }
        ), onDismiss: { model.isPanelPresented = false }) { panel in
            panelContent(panel, model: model)
                .presentationDetents(
                    panel == .environment && !Self.opensPanelsExpanded
                        ? [.medium, .large]
                        : [.large]
                )
                .presentationDragIndicator(.visible)
        }
    }

    /// A demo launch that opens a panel opens it fully, so a capture shows the
    /// whole picker rather than whatever fits the medium detent. Debug only;
    /// in a normal launch this is always false and the sheet behaves as before.
    private static var opensPanelsExpanded: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-paperbound-demo-panel")
        #else
        return false
        #endif
    }

    @ViewBuilder
    private func readingSurface(_ model: ReaderViewModel) -> some View {
        switch model.mode {
        case .physical:
            if let provider = model.provider {
                PagedReaderView(model: model, provider: provider)
            }
        case .document:
            if let document = model.engine?.pdfDocument {
                NativePDFReaderView(
                    document: document,
                    pageIndex: model.currentPageIndex,
                    twoUp: model.layout.mode == .spread,
                    backgroundColor: UIColor(model.environment.presentation.surroundColor.swiftUIColor),
                    highlightedSelections: [],
                    onPageChange: { index in
                        model.reportVisible(pageIndex: index)
                    }
                )
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        model.showsControls.toggle()
                    }
                }
            }
        }
    }

    private func failureView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("This book could not be opened")
                .font(.headline)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Back to library") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: 420)
    }

    // MARK: - Controls

    private func topBar(_ model: ReaderViewModel) -> some View {
        HStack(spacing: 14) {
            Button {
                model.unload()
                dismiss()
            } label: {
                Label("Library", systemImage: "chevron.left")
                    .labelStyle(.iconOnly)
                    .font(.title3.weight(.semibold))
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(book.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(model.environment.name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { model.toggleMode() }
            } label: {
                Label(model.mode.displayName, systemImage: model.mode.systemImage)
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)

            Button {
                model.toggleBookmark()
            } label: {
                Image(systemName: model.currentPageIsBookmarked ? "bookmark.fill" : "bookmark")
                    .font(.title3)
            }

            Menu {
                Button {
                    model.activePanel = .environment
                } label: {
                    Label("Reading environment", systemImage: "paintpalette")
                }
                Button {
                    model.activePanel = .contents
                } label: {
                    Label("Contents", systemImage: "list.bullet")
                }
                Button {
                    model.activePanel = .bookmarks
                } label: {
                    Label("Bookmarks", systemImage: "bookmark")
                }
                Button {
                    model.activePanel = .search
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                Divider()
                Button {
                    model.toggleSpeech()
                } label: {
                    Label(
                        model.speech.isSpeaking ? "Stop reading aloud" : "Read this page aloud",
                        systemImage: model.speech.isSpeaking ? "stop.circle" : "speaker.wave.2"
                    )
                }
                Divider()
                Button {
                    book.isFavorite.toggle()
                } label: {
                    Label(
                        book.isFavorite ? "Remove from favourites" : "Add to favourites",
                        systemImage: book.isFavorite ? "heart.fill" : "heart"
                    )
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func bottomBar(_ model: ReaderViewModel) -> some View {
        VStack(spacing: 8) {
            if model.pageCount > 1 {
                Slider(
                    value: Binding(
                        get: { model.sliderSelection ?? Double(model.currentPageIndex) },
                        set: { model.sliderSelection = $0 }
                    ),
                    in: 0...Double(max(1, model.pageCount - 1)),
                    step: 1,
                    onEditingChanged: { editing in
                        if editing { model.sliderSelection = Double(model.currentPageIndex) }
                        else { model.commitSlider() }
                    }
                )
                .accessibilityIdentifier("reader.pageSlider")
            }
            HStack {
                Text(model.sliderSelection.map { "Page \(Int($0.rounded()) + 1) of \(model.pageCount)" } ?? model.positionLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.layout.mode == .spread {
                    Label("Two pages", systemImage: "book")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text("\(Int((model.progress * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.bar)
    }

    // MARK: - Panels

    @ViewBuilder
    private func panelContent(_ panel: ReaderPanel, model: ReaderViewModel) -> some View {
        switch panel {
        case .environment:
            EnvironmentEditorView(model: model)
        case .contents:
            ContentsPanelView(model: model)
        case .bookmarks:
            BookmarksPanelView(model: model)
        case .search:
            SearchPanelView(model: model)
        }
    }
}
