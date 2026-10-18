//
//  TypographyPreferences.swift
//  Paperbound
//
//  The one place `TypographySettings` becomes Readium `EPUBPreferences`.
//  Pure and synchronous, so it is unit-tested directly
//  (`TypographyTests.testMapping…`).
//
//  Only typography keys are set here. Layout keys (`columnCount`, `spread`,
//  `scroll`, `readingProgression`, `offsetFirstPage`) are left nil so the
//  reader surface can merge its own: `layout.merging(typography)` or the
//  reverse gives the same result because the two never overlap.
//

import Foundation
import ReadiumNavigator
import ReadiumShared

enum TypographyPreferences {

    static func preferences(for settings: TypographySettings) -> EPUBPreferences {
        EPUBPreferences(
            backgroundColor: readiumColor(settings.backgroundColor),
            fontFamily: settings.font.cssFamily.map { FontFamily(rawValue: $0) },
            fontSize: settings.fontScale,
            imageFilter: settings.theme == .night ? .darken : nil,
            lineHeight: settings.lineHeight,
            pageMargins: settings.pageMargins,
            // Readium ignores line height and alignment while publisher
            // styles are on, and leaves the book's design alone otherwise.
            publisherStyles: !settings.overridesPublisherStyles,
            textAlign: textAlign(settings.justification),
            textColor: readiumColor(settings.effectiveTextColor),
            theme: readiumTheme(settings.theme)
        )
    }

    /// The Readium base theme. Grey and Night use Readium's dark mode so that
    /// its night stylesheet (links, borders, image handling) applies; the
    /// exact page and ink colours are then set by `backgroundColor` and
    /// `textColor`, which take precedence over the theme's.
    static func readiumTheme(_ theme: TypographyTheme) -> Theme {
        switch theme {
        case .paper: return .light
        case .sepia: return .sepia
        case .grey, .night: return .dark
        }
    }

    static func textAlign(_ justification: TypographyJustification) -> ReadiumNavigator.TextAlignment? {
        switch justification {
        case .publisher: return nil
        case .left: return .left
        case .justified: return .justify
        }
    }

    /// Readium colours are packed 0xRRGGBB integers; alpha is not supported.
    static func readiumColor(_ color: RGBAColor) -> ReadiumNavigator.Color {
        func byte(_ c: Double) -> Int { Int((c.clamped(to: 0...1) * 255).rounded()) }
        return ReadiumNavigator.Color(
            rawValue: (byte(color.red) << 16) | (byte(color.green) << 8) | byte(color.blue)
        )
    }
}

extension TypographySettings {
    /// Shorthand for `TypographyPreferences.preferences(for: self)`.
    var epubPreferences: EPUBPreferences { TypographyPreferences.preferences(for: self) }
}

// MARK: - Applying live, on the same text

/// Submits typography to the open book and keeps the reader on the text they
/// were reading.
///
/// Readium applies a preference change by updating CSS properties in the
/// page already loaded (`readium.setCSSProperties`) and then only snaps to
/// the nearest page *by scroll offset*: it does not re-locate. Making the
/// text smaller therefore leaves the reader on "page 2" of a chapter that now
/// has far fewer pages, i.e. further on in the text (verified in
/// `TypographyNavigatorTests`). So before the first change of a burst we ask
/// Readium for the first visible element (a Locator with its CSS selector and
/// text), and once the re-flow settles we go back to it. A slider dragged
/// across several stops keeps the anchor from before the drag.
@MainActor
final class TypographyLiveApplier {

    /// How long the web view gets to re-flow before we re-locate.
    static let settleDelay: Duration = .milliseconds(350)

    private var anchor: Locator?
    private var restoreTask: Task<Void, Never>?

    func apply(_ settings: TypographySettings, through bridge: EPUBNavigatorBridge) {
        let preferences = settings.epubPreferences
        guard preferences != bridge.submittedPreferences else { return }
        guard let navigator = bridge.navigator else {
            // Not on screen: remembered and used when the navigator is built.
            bridge.submit(preferences)
            return
        }
        restoreTask?.cancel()
        restoreTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if self.anchor == nil {
                self.anchor = await navigator.firstVisibleElementLocator() ?? navigator.currentLocation
            }
            // A newer change took over while we waited; it submits its own.
            guard !Task.isCancelled else { return }
            bridge.submit(preferences)
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled, bridge.navigator === navigator, let anchor = self.anchor else { return }
            _ = await navigator.go(to: anchor, options: NavigatorGoOptions(animated: false))
            guard !Task.isCancelled else { return }
            self.anchor = nil
            self.restoreTask = nil
        }
    }
}
