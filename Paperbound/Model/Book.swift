//
//  Book.swift
//  Paperbound
//
//  SwiftData records. The original imported file is never touched — these
//  models only ever hold metadata, position and appearance choices.
//

import Foundation
import SwiftData

enum BookFormat: String, Codable, CaseIterable, Sendable {
    case pdf
    case epub

    var displayName: String {
        switch self {
        case .pdf: return "PDF"
        case .epub: return "EPUB"
        }
    }

    var fileExtension: String { rawValue }

    static func from(fileExtension ext: String) -> BookFormat? {
        BookFormat(rawValue: ext.lowercased())
    }
}

@Model
final class Book {
    /// Stable identity used in render caches and damage seeds.
    @Attribute(.unique) var id: UUID

    var title: String
    var author: String?

    /// File name inside the app's managed Books directory. Never an outside path.
    var fileName: String
    var formatRaw: String

    var addedAt: Date
    var lastOpenedAt: Date?
    var isFavorite: Bool
    var isFinished: Bool

    /// Best-known page/segment count. 0 when not yet opened.
    var pageCount: Int
    /// 0…1, used for shelf progress rings and sorting.
    var progress: Double

    /// Encoded `ReadingLocation`.
    var locationData: Data?
    /// Encoded `ReadingEnvironment`; nil means "follow the global default".
    var environmentData: Data?
    /// Per-book wear identity. Two copies of the same file wear differently.
    var wearSeedRaw: Int

    /// JPEG cover thumbnail.
    @Attribute(.externalStorage) var coverData: Data?

    /// Content hash used to detect re-imports of the same file.
    var contentFingerprint: String

    @Relationship(deleteRule: .cascade, inverse: \Bookmark.book)
    var bookmarks: [Bookmark]

    @Relationship(deleteRule: .cascade, inverse: \Highlight.book)
    var highlights: [Highlight]

    init(
        id: UUID = UUID(),
        title: String,
        author: String? = nil,
        fileName: String,
        format: BookFormat,
        contentFingerprint: String,
        addedAt: Date = .now,
        wearSeed: UInt64 = UInt64.random(in: UInt64.min...UInt64.max)
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.fileName = fileName
        self.formatRaw = format.rawValue
        self.contentFingerprint = contentFingerprint
        self.addedAt = addedAt
        self.lastOpenedAt = nil
        self.isFavorite = false
        self.isFinished = false
        self.pageCount = 0
        self.progress = 0
        self.locationData = nil
        self.environmentData = nil
        self.wearSeedRaw = Int(bitPattern: UInt(truncatingIfNeeded: wearSeed))
        self.coverData = nil
        self.bookmarks = []
        self.highlights = []
    }

    // MARK: Derived

    var format: BookFormat {
        BookFormat(rawValue: formatRaw) ?? .pdf
    }

    /// SwiftData stores signed integers; the generator wants the raw bit pattern.
    var wearSeed: UInt64 {
        get { UInt64(bitPattern: Int64(wearSeedRaw)) }
        set { wearSeedRaw = Int(bitPattern: UInt(truncatingIfNeeded: newValue)) }
    }

    var savedLocation: ReadingLocation? {
        get {
            guard let locationData else { return nil }
            return try? JSONDecoder().decode(ReadingLocation.self, from: locationData)
        }
        set {
            locationData = newValue.flatMap { try? JSONEncoder().encode($0) }
        }
    }

    var savedEnvironment: ReadingEnvironment? {
        get {
            guard let environmentData else { return nil }
            return (try? JSONDecoder().decode(ReadingEnvironment.self, from: environmentData))?.effectsOnly
        }
        set {
            environmentData = newValue.flatMap { try? JSONEncoder().encode($0.effectsOnly) }
        }
    }

    var displayAuthor: String {
        if let author, !author.trimmingCharacters(in: .whitespaces).isEmpty { return author }
        return "Unknown author"
    }

    var sortedBookmarks: [Bookmark] {
        bookmarks.sorted { $0.orderKey < $1.orderKey }
    }

    var sortedHighlights: [Highlight] {
        highlights.sorted { $0.orderKey < $1.orderKey }
    }
}

@Model
final class Bookmark {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var label: String
    var locationData: Data?
    /// Numeric key for ordering across formats (page index, or progression × 10⁶).
    var orderKey: Double
    var book: Book?

    init(
        id: UUID = UUID(),
        label: String,
        location: ReadingLocation,
        orderKey: Double,
        createdAt: Date = .now
    ) {
        self.id = id
        self.label = label
        self.orderKey = orderKey
        self.createdAt = createdAt
        self.locationData = try? JSONEncoder().encode(location)
        self.book = nil
    }

    var location: ReadingLocation {
        guard let locationData,
              let decoded = try? JSONDecoder().decode(ReadingLocation.self, from: locationData)
        else { return .start }
        return decoded
    }
}

@Model
final class Highlight {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    /// The text the reader selected, stored so the highlight survives re-layout.
    var quotedText: String
    var note: String
    var colorRaw: String
    var locationData: Data?
    /// Normalized rectangles on the page, encoded as `[x, y, w, h]` groups.
    var rectsData: Data?
    var orderKey: Double
    var book: Book?
    /// How the mark is drawn. Defaulted so stores written before styles
    /// existed migrate without a schema version.
    var styleRaw: String = HighlightStyle.highlight.rawValue
    /// Character range in the page's text layer, so the mark can be redrawn
    /// from the text itself. -1 when unknown (marks made before ranges were kept).
    var rangeLocation: Int = -1
    var rangeLength: Int = 0

    init(
        id: UUID = UUID(),
        quotedText: String,
        note: String = "",
        color: HighlightColor = .butter,
        style: HighlightStyle = .highlight,
        location: ReadingLocation,
        normalizedRects: [CGRect],
        characterRange: NSRange? = nil,
        orderKey: Double,
        createdAt: Date = .now
    ) {
        self.id = id
        self.quotedText = quotedText
        self.note = note
        self.colorRaw = color.rawValue
        self.styleRaw = style.rawValue
        self.rangeLocation = characterRange?.location ?? -1
        self.rangeLength = characterRange?.length ?? 0
        self.orderKey = orderKey
        self.createdAt = createdAt
        self.locationData = try? JSONEncoder().encode(location)
        let flat = normalizedRects.flatMap { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] }
        self.rectsData = try? JSONEncoder().encode(flat)
        self.book = nil
    }

    var color: HighlightColor {
        get { HighlightColor(rawValue: colorRaw) ?? .butter }
        set { colorRaw = newValue.rawValue }
    }

    var style: HighlightStyle {
        get { HighlightStyle(rawValue: styleRaw) ?? .highlight }
        set { styleRaw = newValue.rawValue }
    }

    var characterRange: NSRange? {
        rangeLocation >= 0 ? NSRange(location: rangeLocation, length: rangeLength) : nil
    }

    /// The mark as the page overlay draws it.
    var pageMark: PageMark {
        PageMark(id: id, style: style, color: color, lineRects: normalizedRects,
                 hasNote: !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var location: ReadingLocation {
        guard let locationData,
              let decoded = try? JSONDecoder().decode(ReadingLocation.self, from: locationData)
        else { return .start }
        return decoded
    }

    var normalizedRects: [CGRect] {
        guard let rectsData,
              let flat = try? JSONDecoder().decode([Double].self, from: rectsData)
        else { return [] }
        return stride(from: 0, to: flat.count - 3, by: 4).map { i in
            CGRect(x: flat[i], y: flat[i + 1], width: flat[i + 2], height: flat[i + 3])
        }
    }
}

enum HighlightColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case butter
    case rose
    case moss
    case sky
    case pencil

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .butter: return "Butter"
        case .rose: return "Rose"
        case .moss: return "Moss"
        case .sky: return "Sky"
        case .pencil: return "Pencil"
        }
    }

    var color: RGBAColor {
        switch self {
        case .butter: return RGBAColor(hex: 0xF2D65C, alpha: 0.45)
        case .rose: return RGBAColor(hex: 0xE08A8A, alpha: 0.42)
        case .moss: return RGBAColor(hex: 0x8FBF72, alpha: 0.42)
        case .sky: return RGBAColor(hex: 0x7FB2E0, alpha: 0.42)
        case .pencil: return RGBAColor(hex: 0x8A8A8A, alpha: 0.35)
        }
    }
}
