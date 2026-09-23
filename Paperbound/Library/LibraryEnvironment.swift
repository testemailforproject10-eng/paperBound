//
//  LibraryEnvironment.swift
//  Paperbound
//
//  Wraps the file-owning `LibraryStore` so views can reach it through the
//  SwiftUI environment, and carries the import status the library screen shows.
//

import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class LibraryEnvironment {

    let store: LibraryStore

    var importError: String?
    var importNotice: String?
    var isImporting = false

    init(store: LibraryStore) {
        self.store = store
    }

    func importFiles(_ urls: [URL], into context: ModelContext) {
        guard !urls.isEmpty else { return }
        isImporting = true
        importError = nil
        importNotice = nil

        var imported = 0
        var reused = 0
        var failures: [String] = []

        for url in urls {
            do {
                let outcome = try store.importFile(at: url, into: context)
                if outcome.wasAlreadyPresent { reused += 1 } else { imported += 1 }
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        isImporting = false

        if !failures.isEmpty {
            importError = failures.joined(separator: "\n")
        }
        if reused > 0 && failures.isEmpty {
            importNotice = imported > 0
                ? "Added \(imported), and \(reused) were already in your library."
                : (reused == 1 ? "That book is already in your library." : "Those books are already in your library.")
        }
    }

    func installSample(into context: ModelContext) {
        do {
            _ = try SampleLibrary.installIfNeeded(store: store, context: context)
        } catch {
            importError = "The sample book could not be created: \(error.localizedDescription)"
        }
    }

    func delete(_ book: Book, from context: ModelContext) {
        do {
            try store.delete(book, from: context)
        } catch {
            importError = "That book could not be removed: \(error.localizedDescription)"
        }
    }
}
