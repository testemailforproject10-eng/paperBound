//
//  EPUBAnnotationsDecorations.swift
//  Paperbound
//
//  How Paperbound's marks are drawn on EPUB: each `Highlight` becomes a
//  Readium `Decoration`, and each `HighlightStyle` a decoration style.
//
//    highlight      Readium's built-in `highlight` (a tinted box per line)
//    underline      Readium's built-in `underline` (a 2 px rule under each line)
//    strikethrough  custom `paperbound-strikethrough`: a rule through the
//                   middle of each line box
//    squiggly       custom `paperbound-squiggly`: a repeating wave under each
//                   line, drawn by an inline SVG coloured per decoration
//
//  All four use `HighlightConfig` (tint + isActive) as their config, so the
//  colour of a mark is always `HighlightColor.color` at full strength and the
//  template applies its own opacity. `isActive` is set on the mark that is
//  open in the action bar; it adds an underline to a highlight, the way
//  Readium's own templates show an active mark.
//
//  The templates are creation-time configuration (see EPUBNavigatorBridge),
//  installed by `EPUBAnnotationsController.install(model:)` before the first
//  navigator is built.
//

import ReadiumNavigator
import ReadiumShared
import UIKit

enum EPUBAnnotationDecorations {

    /// Decoration group of saved marks.
    static let highlightsGroup: DecorationGroup = "paperbound-highlights"
    /// Decoration group of the search result just jumped to.
    static let searchGroup: DecorationGroup = "paperbound-search"

    static let strikethroughStyle: Decoration.Style.Id = "paperbound-strikethrough"
    static let squigglyStyle: Decoration.Style.Id = "paperbound-squiggly"

    /// The decoration style id for one of our styles.
    static func styleID(for style: HighlightStyle) -> Decoration.Style.Id {
        switch style {
        case .highlight: return .highlight
        case .underline: return .underline
        case .strikethrough: return strikethroughStyle
        case .squiggly: return squigglyStyle
        }
    }

    /// The Readium style for a mark.
    static func style(for style: HighlightStyle, color: HighlightColor, isActive: Bool = false) -> Decoration.Style {
        Decoration.Style(
            id: styleID(for: style),
            config: Decoration.Style.HighlightConfig(tint: tint(for: color), isActive: isActive)
        )
    }

    /// The mark's colour at full strength; templates apply their own opacity.
    static func tint(for color: HighlightColor) -> UIColor {
        let rgba = color.color
        return UIColor(red: CGFloat(rgba.red), green: CGFloat(rgba.green), blue: CGFloat(rgba.blue), alpha: 1)
    }

    /// One decoration per EPUB highlight. Highlights without a usable locator
    /// (PDF marks) are skipped.
    static func decorations(for highlights: [Highlight], activeID: UUID? = nil) -> [Decoration] {
        highlights
            .sorted { $0.createdAt < $1.createdAt }
            .compactMap { highlight in
                guard let locator = highlight.epubLocator else { return nil }
                return Decoration(
                    id: highlight.id.uuidString,
                    locator: locator,
                    style: style(for: highlight.style, color: highlight.color, isActive: highlight.id == activeID)
                )
            }
    }

    /// The temporary mark on a search result.
    static func searchDecoration(for result: ReadingSearchResult) -> Decoration? {
        guard let locator = result.location.readiumLocator else { return nil }
        return Decoration(
            id: "search-\(result.id.uuidString)",
            locator: locator,
            style: .highlight(tint: tint(for: .butter), isActive: true)
        )
    }

    // MARK: Templates

    /// Readium's defaults for highlight and underline, plus our two custom
    /// styles. Opacity matches the PDF marks (≈0.45 for highlights).
    static func templates() -> [Decoration.Style.Id: HTMLDecorationTemplate] {
        var templates = HTMLDecorationTemplate.defaultTemplates(
            defaultTint: tint(for: .butter), lineWeight: 2, cornerRadius: 3, alpha: 0.45
        )
        templates[strikethroughStyle] = strikethroughTemplate
        templates[squigglyStyle] = squigglyTemplate
        return templates
    }

    private static func config(of decoration: Decoration) -> Decoration.Style.HighlightConfig {
        (decoration.style.config as? Decoration.Style.HighlightConfig)
            ?? Decoration.Style.HighlightConfig(tint: tint(for: .butter))
    }

    /// `rgba(…)` for a tint, built here because Readium's `cssValue` is internal.
    static func css(_ color: UIColor, alpha: CGFloat) -> String {
        var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return "rgba(\(Int(r * 255)), \(Int(g * 255)), \(Int(b * 255)), \(alpha))"
    }

    static let strikethroughTemplate = HTMLDecorationTemplate(
        layout: .boxes,
        element: { decoration in
            let config = config(of: decoration)
            let color = css(config.tint ?? tint(for: .butter), alpha: 0.95)
            let active = config.isActive ? "background-color: \(css(config.tint ?? .yellow, alpha: 0.18));" : ""
            return "<div class=\"paperbound-strike\" style=\"--pb-mark: \(color); \(active)\"/>"
        },
        stylesheet: """
        .paperbound-strike { box-sizing: border-box; border-radius: 2px; }
        .paperbound-strike::after {
            content: ""; position: absolute; left: 0; right: 0; top: 50%;
            margin-top: -1px; border-top: 2px solid var(--pb-mark);
        }
        """
    )

    static let squigglyTemplate = HTMLDecorationTemplate(
        layout: .boxes,
        element: { decoration in
            let config = config(of: decoration)
            let tint = config.tint ?? tint(for: .butter)
            var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            tint.getRed(&r, green: &g, blue: &b, alpha: &a)
            let hex = String(format: "%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
            // A 6×4 wave, repeated along the bottom of the line box.
            // Percent-encoded: the element may be parsed as XML (XHTML), where
            // a raw `<` inside an attribute is an error.
            let svg = "%3Csvg xmlns='http://www.w3.org/2000/svg' width='6' height='4' viewBox='0 0 6 4'%3E"
                + "%3Cpath d='M0 3 Q1.5 0 3 2 T6 1' fill='none' stroke='%23\(hex)' stroke-width='1.2'/%3E%3C/svg%3E"
            let active = config.isActive ? "background-color: \(css(tint, alpha: 0.18));" : ""
            return "<div class=\"paperbound-squiggle\" style=\"--pb-wave: url(&quot;data:image/svg+xml;utf8,\(svg)&quot;); \(active)\"/>"
        },
        stylesheet: """
        .paperbound-squiggle { box-sizing: border-box; border-radius: 2px; }
        .paperbound-squiggle::after {
            content: ""; position: absolute; left: 0; right: 0; bottom: -2px; height: 4px;
            background-image: var(--pb-wave); background-repeat: repeat-x; background-size: 6px 4px;
        }
        """
    )
}
