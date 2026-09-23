//
//  AppSettings.swift
//  Paperbound
//
//  Preferences that are not tied to one book. Deliberately UserDefaults rather
//  than SwiftData: they are small, read on every frame of the reader, and must
//  survive a store migration without ceremony.
//

import Foundation
import Observation

@MainActor
@Observable
final class AppSettings {

    private enum Key {
        static let defaultEnvironment = "settings.defaultEnvironment"
        static let spreadPreference = "settings.spreadPreference"
        static let keepScreenAwake = "settings.keepScreenAwake"
        static let speechRate = "settings.speechRate"
        static let librarySort = "settings.librarySort"
    }

    private let defaults: UserDefaults

    /// Used by any book that has not chosen its own environment.
    var defaultEnvironment: ReadingEnvironment {
        didSet { persistEnvironment() }
    }

    var spreadPreference: SpreadPreference {
        didSet { defaults.set(spreadPreference.rawValue, forKey: Key.spreadPreference) }
    }

    var keepScreenAwake: Bool {
        didSet { defaults.set(keepScreenAwake, forKey: Key.keepScreenAwake) }
    }

    /// 0…1, mapped onto AVSpeechUtterance's rate range at use time.
    var speechRate: Double {
        didSet { defaults.set(speechRate, forKey: Key.speechRate) }
    }

    var librarySort: LibrarySort {
        didSet { defaults.set(librarySort.rawValue, forKey: Key.librarySort) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let data = defaults.data(forKey: Key.defaultEnvironment),
           let decoded = try? JSONDecoder().decode(ReadingEnvironment.self, from: data) {
            self.defaultEnvironment = decoded
        } else {
            self.defaultEnvironment = .default
        }

        self.spreadPreference = SpreadPreference(
            rawValue: defaults.string(forKey: Key.spreadPreference) ?? ""
        ) ?? .automatic

        self.keepScreenAwake = defaults.object(forKey: Key.keepScreenAwake) as? Bool ?? true

        self.speechRate = defaults.object(forKey: Key.speechRate) as? Double ?? 0.45

        self.librarySort = LibrarySort(
            rawValue: defaults.string(forKey: Key.librarySort) ?? ""
        ) ?? .recentlyOpened
    }

    private func persistEnvironment() {
        guard let data = try? JSONEncoder().encode(defaultEnvironment) else { return }
        defaults.set(data, forKey: Key.defaultEnvironment)
    }

    /// The environment a book should open with.
    func environment(for book: Book) -> ReadingEnvironment {
        book.savedEnvironment ?? defaultEnvironment
    }
}

enum LibrarySort: String, CaseIterable, Identifiable, Sendable {
    case recentlyOpened
    case recentlyAdded
    case title
    case author
    case progress

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .recentlyOpened: return "Recently opened"
        case .recentlyAdded: return "Recently added"
        case .title: return "Title"
        case .author: return "Author"
        case .progress: return "Progress"
        }
    }

    var systemImage: String {
        switch self {
        case .recentlyOpened: return "clock"
        case .recentlyAdded: return "tray.and.arrow.down"
        case .title: return "textformat.abc"
        case .author: return "person"
        case .progress: return "chart.bar"
        }
    }
}
