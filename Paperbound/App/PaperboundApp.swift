//
//  PaperboundApp.swift
//  Paperbound
//

import SwiftData
import SwiftUI

@main
struct PaperboundApp: App {

    @State private var settings = AppSettings()
    @State private var library: LibraryEnvironment
    @State private var startupError: String?

    private let container: ModelContainer?

    init() {
        // Both the store and the library folder can fail on a device that is
        // out of space. The app still launches and says so, rather than
        // crashing on a force-unwrap in `init`.
        var createdContainer: ModelContainer?
        var createdLibrary: LibraryEnvironment?
        var failure: String?

        do {
            createdContainer = try ModelContainer(
                for: Book.self, Bookmark.self, Highlight.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: false)
            )
        } catch {
            failure = "The library database could not be opened: \(error.localizedDescription)"
        }

        do {
            createdLibrary = LibraryEnvironment(store: try LibraryStore())
        } catch {
            failure = failure ?? "The library folder could not be created: \(error.localizedDescription)"
        }

        self.container = createdContainer
        self._library = State(
            initialValue: createdLibrary ?? LibraryEnvironment(store: LibraryStore.unavailable())
        )
        self._startupError = State(initialValue: failure)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let container {
                    RootView()
                        .modelContainer(container)
                } else {
                    StartupFailureView(message: startupError ?? "Paperbound could not start.")
                }
            }
            .environment(settings)
            .environment(library)
        }
    }
}

struct StartupFailureView: View {
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Paperbound could not start")
                .font(.headline)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(32)
    }
}
