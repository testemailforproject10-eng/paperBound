//
//  TypographyStore.swift
//  Paperbound
//
//  Where typography settings live: one global default in `AppSettings`, plus
//  an optional override per book.
//
//  Per-book overrides are a JSON dictionary in UserDefaults keyed by the
//  book's UUID, not a field on the SwiftData `Book`. Typography is a reading
//  preference like the page-turn style (which already lives here), it is read
//  before the navigator is built, and keeping it out of the store means no
//  schema change, no migration and nothing for the library's import or
//  fingerprint code to carry. The cost is that deleting a book leaves a few
//  hundred bytes behind; `removeTypographyOverride(for:)` exists for the
//  library to call if that ever matters.
//

import Foundation

extension AppSettings {

    /// The typography an EPUB book should open with: its own override if it
    /// has one, else the global default.
    func typography(for bookID: UUID) -> TypographySettings {
        epubTypographyOverrides[bookID] ?? epubTypography
    }

    func hasTypographyOverride(for bookID: UUID) -> Bool {
        epubTypographyOverrides[bookID] != nil
    }

    /// Saves an edit where it belongs: into the book's override when it has
    /// one, otherwise into the global default every other book follows.
    func setTypography(_ settings: TypographySettings, for bookID: UUID) {
        if epubTypographyOverrides[bookID] != nil {
            epubTypographyOverrides[bookID] = settings
        } else {
            epubTypography = settings
        }
    }

    /// Turning the override on starts it from what the book shows now, so the
    /// page does not change; turning it off returns the book to the default.
    func setTypographyOverride(_ enabled: Bool, for bookID: UUID) {
        if enabled {
            guard epubTypographyOverrides[bookID] == nil else { return }
            epubTypographyOverrides[bookID] = epubTypography
        } else {
            removeTypographyOverride(for: bookID)
        }
    }

    func removeTypographyOverride(for bookID: UUID) {
        epubTypographyOverrides[bookID] = nil
    }
}

// MARK: - Encoding helpers (used by AppSettings)

extension TypographySettings {

    static func decodeGlobal(_ data: Data?) -> TypographySettings {
        guard let data, let decoded = try? JSONDecoder().decode(TypographySettings.self, from: data) else {
            return .default
        }
        return decoded
    }

    static func encodeGlobal(_ settings: TypographySettings) -> Data? {
        try? JSONEncoder().encode(settings)
    }

    /// Book ids are stored as strings (JSON object keys). Entries whose key is
    /// not a UUID, or whose value does not decode, are dropped rather than
    /// failing the whole dictionary.
    static func decodeOverrides(_ data: Data?) -> [UUID: TypographySettings] {
        guard let data,
              let raw = try? JSONDecoder().decode([String: LossyTypography].self, from: data) else {
            return [:]
        }
        var result: [UUID: TypographySettings] = [:]
        for (key, value) in raw {
            guard let id = UUID(uuidString: key), let settings = value.settings else { continue }
            result[id] = settings
        }
        return result
    }

    static func encodeOverrides(_ overrides: [UUID: TypographySettings]) -> Data? {
        let raw = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.uuidString, $0.value) })
        return try? JSONEncoder().encode(raw)
    }

    private struct LossyTypography: Decodable {
        let settings: TypographySettings?
        init(from decoder: Decoder) throws {
            settings = try? TypographySettings(from: decoder)
        }
    }
}
