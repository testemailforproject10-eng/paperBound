//
//  LibraryView.swift
//  Paperbound
//
//  The shelf: import, organise, search, sort, open.
//

import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {

    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryEnvironment.self) private var library

    @Query private var books: [Book]

    @State private var searchText = ""
    @State private var showFileImporter = false
    @State private var showFavoritesOnly = false
    @State private var pendingDeletion: Book?
    @State private var path: [Book] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if books.isEmpty {
                    emptyShelf
                } else if visibleBooks.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    shelf
                }
            }
            .navigationTitle("Library")
            .toolbar { toolbarContent }
            .searchable(text: $searchText, prompt: "Title or author")
            .navigationDestination(for: Book.self) { book in
                ReaderView(book: book)
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: LibraryStore.importableTypes,
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case let .success(urls):
                    library.importFiles(urls, into: context)
                case let .failure(error):
                    library.importError = error.localizedDescription
                }
            }
            .alert(
                "Import problem",
                isPresented: Binding(
                    get: { library.importError != nil },
                    set: { if !$0 { library.importError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { library.importError = nil }
            } message: {
                Text(library.importError ?? "")
            }
            .alert(
                "Remove “\(pendingDeletion?.title ?? "")”?",
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }
                )
            ) {
                Button("Remove", role: .destructive) {
                    if let book = pendingDeletion {
                        library.delete(book, from: context)
                    }
                    pendingDeletion = nil
                }
                Button("Cancel", role: .cancel) { pendingDeletion = nil }
            } message: {
                Text("The imported copy, its reading position and its wear pattern will be deleted. Your original file is untouched.")
            }
            .task { await openDemoBookIfRequested() }
            .overlay(alignment: .bottom) {
                if let notice = library.importNotice {
                    Text(notice)
                        .font(.footnote)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task {
                            try? await Task.sleep(for: .seconds(3))
                            withAnimation { library.importNotice = nil }
                        }
                }
            }
        }
    }

    // MARK: - Shelf

    private var shelf: some View {
        GeometryReader { geometry in
            let columns = max(2, Int(geometry.size.width / 150))
            let spacing: CGFloat = 18
            let tileWidth = (geometry.size.width - spacing * CGFloat(columns + 1)) / CGFloat(columns)

            ScrollView {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.fixed(tileWidth), spacing: spacing, alignment: .top),
                        count: columns
                    ),
                    spacing: 26
                ) {
                    ForEach(visibleBooks) { book in
                        NavigationLink(value: book) {
                            BookTileView(
                                book: book,
                                environment: settings.environment(for: book),
                                width: tileWidth
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            bookMenu(book)
                        }
                    }
                }
                .padding(.horizontal, spacing)
                .padding(.vertical, 20)
            }
        }
    }

    @ViewBuilder
    private func bookMenu(_ book: Book) -> some View {
        Button {
            book.isFavorite.toggle()
            try? context.save()
        } label: {
            Label(
                book.isFavorite ? "Remove from favourites" : "Add to favourites",
                systemImage: book.isFavorite ? "heart.slash" : "heart"
            )
        }
        Button {
            book.isFinished.toggle()
            try? context.save()
        } label: {
            Label(
                book.isFinished ? "Mark as unfinished" : "Mark as finished",
                systemImage: book.isFinished ? "arrow.uturn.backward" : "checkmark.circle"
            )
        }
        if book.progress > 0 {
            Button {
                book.progress = 0
                book.savedLocation = nil
                book.isFinished = false
                try? context.save()
            } label: {
                Label("Start again", systemImage: "backward.end")
            }
        }
        Divider()
        Button(role: .destructive) {
            pendingDeletion = book
        } label: {
            Label("Remove from library", systemImage: "trash")
        }
    }

    // MARK: - Empty state

    private var emptyShelf: some View {
        ContentUnavailableView {
            Label("Your shelf is empty", systemImage: "books.vertical")
        } description: {
            Text("Import a PDF from Files, or start with the sample book that ships with Paperbound.")
        } actions: {
            VStack(spacing: 12) {
                Button {
                    showFileImporter = true
                } label: {
                    Label("Import a PDF", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    library.installSample(into: context)
                } label: {
                    Label("Add the sample book", systemImage: "book")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Picker("Sort by", selection: Binding(
                    get: { settings.librarySort },
                    set: { settings.librarySort = $0 }
                )) {
                    ForEach(LibrarySort.allCases) { sort in
                        Label(sort.displayName, systemImage: sort.systemImage).tag(sort)
                    }
                }
                Divider()
                Toggle(isOn: $showFavoritesOnly) {
                    Label("Favourites only", systemImage: "heart")
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down.circle")
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    showFileImporter = true
                } label: {
                    Label("Import a PDF", systemImage: "square.and.arrow.down")
                }
                Button {
                    library.installSample(into: context)
                } label: {
                    Label("Add the sample book", systemImage: "book")
                }
                Divider()
                NavigationLink {
                    SettingsView()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            } label: {
                Image(systemName: "plus.circle")
            }
        }
    }

    // MARK: - Screenshot support

    /// Launching with `-paperbound-demo` installs the sample book and opens it
    /// immediately, so the reader screen can be captured without tapping.
    /// `-paperbound-demo-condition <pristine|lightWear|wellLoved|damaged>`
    /// picks the page condition to open with. Debug builds only.
    /// Set once per process. `path.isEmpty` cannot stand in for this: it is
    /// true exactly when the reader has been dismissed, so on its own it made
    /// every return to the shelf re-push the same book and left the demo
    /// launch unable to open anything else.
    @MainActor private static var didAutoOpenDemoBook = false

    private func openDemoBookIfRequested() async {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-paperbound-demo"),
              !Self.didAutoOpenDemoBook,
              path.isEmpty
        else { return }
        // Claimed before the first await, so a re-entrant call during the
        // install cannot push the book twice.
        Self.didAutoOpenDemoBook = true

        if let index = arguments.firstIndex(of: "-paperbound-demo-condition"),
           index + 1 < arguments.count,
           let condition = PageCondition(rawValue: arguments[index + 1]) {
            var environment = ReadingEnvironment.wellReadPaperback
            environment.condition = condition
            environment.intensity = condition == .pristine ? 0 : 0.85
            settings.defaultEnvironment = environment
        }

        // `-paperbound-demo-theme <slug>` opens in one of the themed
        // environments, named by the part of its id after "theme." — so
        // `cursed`, `stone`, `gilded`, `fieldguide`, `grimoire` and the rest.
        // Applied after the condition block so that passing both lets the
        // theme win, which is what "show me this theme" should mean.
        if let index = arguments.firstIndex(of: "-paperbound-demo-theme"),
           index + 1 < arguments.count {
            let slug = arguments[index + 1]
            if let themed = ReadingEnvironment.themedPresets.first(
                where: { $0.id == "theme.\(slug)" || $0.id == slug }
            ) {
                settings.defaultEnvironment = themed
            }
        }

        library.installSample(into: context)
        // Let the @Query result land before pushing the reader.
        try? await Task.sleep(for: .milliseconds(200))
        guard let book = visibleBooks.first else { return }

        // `-paperbound-demo-page N` opens at a chosen page (1-based), so a
        // screenshot can be compared against the same page in ./Screenshots.
        if let index = arguments.firstIndex(of: "-paperbound-demo-page"),
           index + 1 < arguments.count,
           let page = Int(arguments[index + 1]), page > 0 {
            book.savedLocation = .pdfPage(index: page - 1, yOffset: 0)
        }
        // A demo launch must show the environment it was asked for, not one a
        // previous run happened to leave on the book.
        book.savedEnvironment = nil
        try? context.save()

        path = [book]
        #endif
    }

    // MARK: - Filtering

    private var visibleBooks: [Book] {
        var result = books

        if showFavoritesOnly {
            result = result.filter(\.isFavorite)
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            result = result.filter { book in
                book.title.localizedCaseInsensitiveContains(query)
                    || (book.author ?? "").localizedCaseInsensitiveContains(query)
            }
        }

        switch settings.librarySort {
        case .recentlyOpened:
            result.sort { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
        case .recentlyAdded:
            result.sort { $0.addedAt > $1.addedAt }
        case .title:
            result.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .author:
            result.sort { $0.displayAuthor.localizedCaseInsensitiveCompare($1.displayAuthor) == .orderedAscending }
        case .progress:
            result.sort { $0.progress > $1.progress }
        }
        return result
    }
}
