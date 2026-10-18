//
//  TypographySettings.swift
//  Paperbound
//
//  How reflowable (EPUB) text is set: typeface, size, colours, margins, line
//  spacing and alignment. A plain value with no Readium dependency, so the
//  model layer and tests can use it freely; `TypographyPreferences.swift`
//  maps it onto Readium's `EPUBPreferences`.
//
//  Decoding is deliberately forgiving: every field is optional on the wire and
//  falls back to its default, and an unknown enum value (a font removed in a
//  later version, say) falls back too. Adding a field later therefore never
//  invalidates what a reader has already saved.
//

import Foundation

struct TypographySettings: Codable, Equatable, Sendable {

    var font: TypographyFont
    /// Base font size as a fraction of the publisher's size (1 = 100%).
    var fontScale: Double
    var theme: TypographyTheme
    /// Replaces the theme's text colour when set.
    var customTextColor: RGBAColor?
    /// Readium's `pageMargins` factor: a multiple of Readium CSS's page gutter
    /// (20 pt on a phone, 30 pt in phone landscape, 40–50 pt on tablets).
    var pageMargins: Double
    /// Unitless CSS line height. `nil` keeps the book's own spacing.
    var lineHeight: Double?
    var justification: TypographyJustification

    init(
        font: TypographyFont = .publisher,
        fontScale: Double = 1.0,
        theme: TypographyTheme = .paper,
        customTextColor: RGBAColor? = nil,
        pageMargins: Double = TypographySettings.defaultPageMargins,
        lineHeight: Double? = nil,
        justification: TypographyJustification = .publisher
    ) {
        self.font = font
        self.fontScale = fontScale.clamped(to: Self.fontScaleRange)
        self.theme = theme
        self.customTextColor = customTextColor
        self.pageMargins = pageMargins.clamped(to: Self.pageMarginsRange)
        self.lineHeight = lineHeight.map { $0.clamped(to: Self.lineHeightRange) }
        self.justification = justification
    }

    /// The book as its publisher set it, on Paper, with a snug margin. This is
    /// what "Publisher defaults" restores.
    static let `default` = TypographySettings()

    // MARK: Ranges and steps

    static let fontScaleRange: ClosedRange<Double> = 0.75...2.5
    /// The size slider's stops. Closer together around 100%, where readers
    /// make fine adjustments, and wider apart at the large end.
    static let fontScaleSteps: [Double] = [
        0.75, 0.85, 0.93, 1.0, 1.08, 1.17, 1.3, 1.45, 1.65, 1.9, 2.2, 2.5,
    ]

    /// The default margin. Readium's own default (1.0) leaves 20 pt either
    /// side of a phone screen, which reads as a wide frame on a narrow page.
    /// Half of that, 10 pt, keeps the text clear of the screen's rounded
    /// corners and bezel without wasting width: "a little gap, not much".
    static let defaultPageMargins: Double = 0.5
    static let pageMarginsRange: ClosedRange<Double> = 0.25...2.5
    /// 5, 10, 15, 20, 30, 40 and 50 pt on a phone.
    static let pageMarginSteps: [Double] = [0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 2.5]

    static let lineHeightRange: ClosedRange<Double> = 1.0...2.2
    /// Stops for the line-spacing slider after its first stop ("Book").
    static let lineHeightSteps: [Double] = [1.2, 1.35, 1.5, 1.65, 1.8, 2.0]

    // MARK: Derived

    /// The colour text is drawn in: the custom colour, else the theme's.
    var effectiveTextColor: RGBAColor { customTextColor ?? theme.textColor }

    var backgroundColor: RGBAColor { theme.backgroundColor }

    /// WCAG contrast of the text against the page.
    var contrastRatio: Double {
        ColorContrast.ratio(effectiveTextColor, backgroundColor)
    }

    /// True when the text falls below WCAG AA for body text (4.5:1).
    var hasLowContrast: Bool { contrastRatio < ColorContrast.aaMinimum }

    /// Line spacing and alignment only take effect once Readium is told to
    /// stop observing the publisher's styles; the other settings do not need
    /// it. Keeping publisher styles whenever possible preserves the book's
    /// own design (drop caps, small caps, poetry indents).
    var overridesPublisherStyles: Bool {
        lineHeight != nil || justification != .publisher
    }

    /// True when every *typesetting* choice is the publisher's (theme and
    /// margins aside).
    var usesPublisherTypesetting: Bool {
        font == .publisher && fontScale == 1.0 && !overridesPublisherStyles
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case font, fontScale, theme, customTextColor, pageMargins, lineHeight, justification
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = TypographySettings.default
        self.init(
            font: (try? c.decodeIfPresent(String.self, forKey: .font))
                .flatMap(TypographyFont.init(rawValue:)) ?? fallback.font,
            fontScale: (try? c.decodeIfPresent(Double.self, forKey: .fontScale)) ?? fallback.fontScale,
            theme: (try? c.decodeIfPresent(String.self, forKey: .theme))
                .flatMap(TypographyTheme.init(rawValue:)) ?? fallback.theme,
            customTextColor: (try? c.decodeIfPresent(RGBAColor.self, forKey: .customTextColor)) ?? nil,
            pageMargins: (try? c.decodeIfPresent(Double.self, forKey: .pageMargins)) ?? fallback.pageMargins,
            lineHeight: (try? c.decodeIfPresent(Double.self, forKey: .lineHeight)) ?? nil,
            justification: (try? c.decodeIfPresent(String.self, forKey: .justification))
                .flatMap(TypographyJustification.init(rawValue:)) ?? fallback.justification
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(font.rawValue, forKey: .font)
        try c.encode(fontScale, forKey: .fontScale)
        try c.encode(theme.rawValue, forKey: .theme)
        try c.encodeIfPresent(customTextColor, forKey: .customTextColor)
        try c.encode(pageMargins, forKey: .pageMargins)
        try c.encodeIfPresent(lineHeight, forKey: .lineHeight)
        try c.encode(justification.rawValue, forKey: .justification)
    }
}

// MARK: - Font

enum TypographyFont: String, CaseIterable, Identifiable, Sendable {
    case publisher
    case newYork
    case georgia
    case palatino
    case iowan
    case avenirNext
    case sfPro
    case openDyslexic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .publisher: return "Book's font"
        case .newYork: return "New York"
        case .georgia: return "Georgia"
        case .palatino: return "Palatino"
        case .iowan: return "Iowan Old Style"
        case .avenirNext: return "Avenir Next"
        case .sfPro: return "San Francisco"
        case .openDyslexic: return "OpenDyslexic"
        }
    }

    var detail: String {
        switch self {
        case .publisher: return "As the publisher set it"
        case .newYork: return "Apple's reading serif"
        case .georgia: return "Sturdy serif, made for screens"
        case .palatino: return "Classic book face"
        case .iowan: return "Warm, bookish old style"
        case .avenirNext: return "Geometric sans"
        case .sfPro: return "The system sans"
        case .openDyslexic: return "Weighted letters for dyslexia"
        }
    }

    /// The CSS `font-family` Readium is given. `nil` keeps the publisher's.
    ///
    /// New York and San Francisco are not addressable by name inside a web
    /// view; WebKit exposes them through the `ui-serif` and `system-ui`
    /// generic families. The others are installed on iOS and addressed by
    /// family name. OpenDyslexic ships inside Readium's navigator bundle,
    /// which declares its `@font-face` itself.
    var cssFamily: String? {
        switch self {
        case .publisher: return nil
        case .newYork: return "ui-serif"
        case .georgia: return "Georgia"
        case .palatino: return "Palatino"
        case .iowan: return "Iowan Old Style"
        case .avenirNext: return "Avenir Next"
        case .sfPro: return "system-ui"
        case .openDyslexic: return "OpenDyslexic"
        }
    }

    /// The PostScript name used to preview the font in the app's own UI.
    /// `nil` for the families SwiftUI reaches through `Font.Design`.
    var previewPostScriptName: String? {
        switch self {
        case .publisher, .newYork, .sfPro: return nil
        case .georgia: return "Georgia"
        case .palatino: return "Palatino-Roman"
        case .iowan: return "IowanOldStyle-Roman"
        case .avenirNext: return "AvenirNext-Regular"
        case .openDyslexic: return "OpenDyslexic-Regular"
        }
    }
}

// MARK: - Theme

enum TypographyTheme: String, CaseIterable, Identifiable, Sendable {
    case paper
    case sepia
    case grey
    case night

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .paper: return "Paper"
        case .sepia: return "Sepia"
        case .grey: return "Grey"
        case .night: return "Night"
        }
    }

    /// Warm off-white rather than #FFFFFF: the app's pages are paper, and pure
    /// white glares at night-time brightness.
    var backgroundColor: RGBAColor {
        switch self {
        case .paper: return RGBAColor(hex: 0xFBF8F1)
        case .sepia: return RGBAColor(hex: 0xF2E6CE)
        case .grey: return RGBAColor(hex: 0x4A4A4D)
        case .night: return RGBAColor(hex: 0x121212)
        }
    }

    /// Each ink clears WCAG AAA (7:1) on its page; see `TypographyTests`.
    var textColor: RGBAColor {
        switch self {
        case .paper: return RGBAColor(hex: 0x1E1B17)
        case .sepia: return RGBAColor(hex: 0x3B2D1C)
        case .grey: return RGBAColor(hex: 0xF0EFEB)
        case .night: return RGBAColor(hex: 0xC9C4BA)
        }
    }

    var isDark: Bool { self == .grey || self == .night }
}

// MARK: - Justification

enum TypographyJustification: String, CaseIterable, Identifiable, Sendable {
    case publisher
    case left
    case justified

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .publisher: return "Book"
        case .left: return "Left"
        case .justified: return "Justified"
        }
    }
}

// MARK: - Contrast

/// WCAG 2.x contrast. https://www.w3.org/TR/WCAG21/#dfn-contrast-ratio
enum ColorContrast {
    /// AA minimum for body text.
    static let aaMinimum: Double = 4.5

    /// WCAG relative luminance (linearised sRGB), not `RGBAColor.luminance`,
    /// which is a gamma-encoded approximation used for rendering choices.
    static func relativeLuminance(_ color: RGBAColor) -> Double {
        func linear(_ c: Double) -> Double {
            let c = c.clamped(to: 0...1)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    /// 1…21, symmetric in its arguments.
    static func ratio(_ a: RGBAColor, _ b: RGBAColor) -> Double {
        let la = relativeLuminance(a)
        let lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}

// MARK: - Demo launch override

#if DEBUG
extension TypographySettings {
    /// `-paperbound-demo-typography "font=georgia,size=2.5,theme=night,margins=0.25,spacing=1.5,align=justified,ink=8A2BE2"`
    /// presets the global typography at launch, so screenshots can show a
    /// setting without tapping (the simulator cannot be tapped from a script).
    /// Unknown keys are ignored; omitted keys keep their defaults.
    static var demoLaunchOverride: TypographySettings? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-paperbound-demo-typography"),
              index + 1 < arguments.count else { return nil }
        return parseDemo(arguments[index + 1])
    }

    static func parseDemo(_ spec: String) -> TypographySettings {
        var result = TypographySettings.default
        for pair in spec.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let value = parts[1]
            switch parts[0] {
            case "font": result.font = TypographyFont(rawValue: value) ?? result.font
            case "size": result.fontScale = (Double(value) ?? 1).clamped(to: fontScaleRange)
            case "theme": result.theme = TypographyTheme(rawValue: value) ?? result.theme
            case "margins": result.pageMargins = (Double(value) ?? defaultPageMargins).clamped(to: pageMarginsRange)
            case "spacing": result.lineHeight = Double(value).map { $0.clamped(to: lineHeightRange) }
            case "align": result.justification = TypographyJustification(rawValue: value) ?? result.justification
            case "ink": result.customTextColor = UInt32(value, radix: 16).map { RGBAColor(hex: $0) }
            default: continue
            }
        }
        return result
    }
}
#endif
