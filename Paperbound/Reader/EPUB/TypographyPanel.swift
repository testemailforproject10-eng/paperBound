//
//  TypographyPanel.swift
//  Paperbound
//
//  "Aa": the EPUB typography sheet. Font, size, theme and ink, margins, line
//  spacing and alignment, with a live sample at the top. Every change is
//  saved at once (globally, or to this book when it has its own settings) and
//  the open book re-flows behind the sheet, which opens at the medium detent
//  so the page stays in view.
//
//  Same shape as the reading-environment sheet: a preview row above an
//  inset-grouped list, picker rows with a trailing checkmark, Done in the
//  navigation bar.
//

import CoreText
import SwiftUI
import UIKit

struct TypographyPanel: View {

    let bookID: UUID
    /// The open book's navigator. `nil` in previews; the settings are still
    /// saved, they just reach the book next time it opens.
    let bridge: EPUBNavigatorBridge?

    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    @State private var applier = TypographyLiveApplier()

    init(bookID: UUID, bridge: EPUBNavigatorBridge? = nil) {
        self.bookID = bookID
        self.bridge = bridge
    }

    init(model: ReaderViewModel) {
        self.init(bookID: model.book.id, bridge: model.epubBridge)
    }

    private var typography: TypographySettings { settings.typography(for: bookID) }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    Section {
                        TypographySample(settings: typography)
                            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                    }
                    sizeSection
                    themeSection
                    fontSection.id("font")
                    layoutSection.id("layout")
                    scopeSection
                    resetSection.id("reset")
                }
                .listStyle(.insetGrouped)
                #if DEBUG
                // `PAPERBOUND_TYPOGRAPHY_SCROLL=font|layout|reset` scrolls the
                // panel for screenshots (the simulator cannot be scrolled).
                .task {
                    if let target = ProcessInfo.processInfo.environment["PAPERBOUND_TYPOGRAPHY_SCROLL"] {
                        try? await Task.sleep(for: .milliseconds(600))
                        proxy.scrollTo(target, anchor: .top)
                    }
                }
                #endif
            }
            .navigationTitle("Text & layout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sensoryFeedback(.selection, trigger: typography)
        // Every change — a control, the per-book toggle, the reset — lands
        // here and goes to the live navigator, which re-flows in place;
        // the applier then puts the reader back on the same text.
        .onChange(of: typography) { _, new in
            if let bridge { applier.apply(new, through: bridge) }
        }
        .onAppear { TypographyFontRegistry.registerBundledFonts() }
        .accessibilityIdentifier("typography-panel")
    }

    // MARK: - Size

    private var sizeSection: some View {
        Section {
            SteppedSlider(
                steps: TypographySettings.fontScaleSteps,
                value: typography.fontScale,
                title: "Text size",
                valueDescription: { "\(Int(($0 * 100).rounded())) percent" },
                minimumLabel: { Text("A").font(.footnote) },
                maximumLabel: { Text("A").font(.title2) }
            ) { new in update { $0.fontScale = new } }
            .accessibilityIdentifier("typography-size")
        } header: {
            HStack {
                Text("Size")
                Spacer()
                Text("\(Int((typography.fontScale * 100).rounded()))%")
                    .monospacedDigit()
            }
        }
    }

    // MARK: - Theme and ink

    private var themeSection: some View {
        Section {
            HStack(spacing: 0) {
                ForEach(TypographyTheme.allCases) { theme in
                    ThemeSwatch(theme: theme, isSelected: typography.theme == theme) {
                        update { $0.theme = theme }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 4)

            InkRow(
                theme: typography.theme,
                customColor: typography.customTextColor
            ) { color in update { $0.customTextColor = color } }

            if typography.customTextColor != nil {
                ContrastNote(ratio: typography.contrastRatio)
            }
        } header: {
            Text("Theme")
        }
    }

    // MARK: - Font

    private var fontSection: some View {
        Section("Font") {
            ForEach(TypographyFont.allCases) { font in
                Button {
                    update { $0.font = font }
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(font.displayName)
                                .font(TypographyFontRegistry.previewFont(font, textStyle: .body))
                                .foregroundStyle(.primary)
                            Text(font.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        if typography.font == font {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(typography.font == font ? .isSelected : [])
                .accessibilityIdentifier("typography-font-\(font.rawValue)")
            }
        }
    }

    // MARK: - Layout

    private var layoutSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                labelledValue("Margins", marginLabel(typography.pageMargins))
                SteppedSlider(
                    steps: TypographySettings.pageMarginSteps,
                    value: typography.pageMargins,
                    title: "Margins",
                    valueDescription: marginLabel,
                    minimumLabel: { Image(systemName: "arrow.right.and.line.vertical.and.arrow.left").font(.footnote) },
                    maximumLabel: { Image(systemName: "arrow.left.and.line.vertical.and.arrow.right").font(.footnote) }
                ) { new in update { $0.pageMargins = new } }
                .accessibilityIdentifier("typography-margins")
            }

            VStack(alignment: .leading, spacing: 6) {
                labelledValue("Line spacing", spacingLabel(typography.lineHeight))
                // Stop 0 is "the book's own"; 1… are explicit heights.
                SteppedSlider(
                    steps: [0] + TypographySettings.lineHeightSteps,
                    value: typography.lineHeight ?? 0,
                    title: "Line spacing",
                    valueDescription: { spacingLabel($0 == 0 ? nil : $0) },
                    minimumLabel: { Image(systemName: "text.alignleft").font(.footnote) },
                    maximumLabel: { Image(systemName: "line.3.horizontal").font(.footnote) }
                ) { new in update { $0.lineHeight = new == 0 ? nil : new } }
                .accessibilityIdentifier("typography-spacing")
            }

            Picker("Alignment", selection: Binding(
                get: { typography.justification },
                set: { value in update { $0.justification = value } }
            )) {
                ForEach(TypographyJustification.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Alignment")
            .accessibilityIdentifier("typography-alignment")
        } header: {
            Text("Layout")
        } footer: {
            if typography.overridesPublisherStyles {
                Text("Custom spacing or alignment sets the book's paragraphs in a plain style.")
            }
        }
    }

    private func labelledValue(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
        .accessibilityHidden(true) // the slider below carries label and value
    }

    private func marginLabel(_ factor: Double) -> String {
        switch factor {
        case ..<0.3: return "Tightest"
        case ..<0.6: return "Snug"
        case ..<0.9: return "Comfortable"
        case ..<1.2: return "Standard"
        case ..<1.75: return "Roomy"
        case ..<2.25: return "Wide"
        default: return "Widest"
        }
    }

    private func spacingLabel(_ height: Double?) -> String {
        guard let height else { return "Book" }
        return String(format: "%g×", height)
    }

    // MARK: - Scope and reset

    private var scopeSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { settings.hasTypographyOverride(for: bookID) },
                set: { settings.setTypographyOverride($0, for: bookID) }
            )) {
                Label("Only for this book", systemImage: "book")
            }
            .accessibilityIdentifier("typography-per-book")
        } footer: {
            Text(settings.hasTypographyOverride(for: bookID)
                 ? "This book keeps its own text settings. Turn off to follow your default again."
                 : "Changes apply to every book that doesn't have its own settings.")
        }
    }

    private var resetSection: some View {
        Section {
            Button(role: .destructive) {
                update { $0 = .default }
            } label: {
                Label("Publisher defaults", systemImage: "arrow.counterclockwise")
            }
            .disabled(typography == .default)
            .accessibilityIdentifier("typography-reset")
        } footer: {
            Text("The book's own font, size, spacing and alignment, on Paper with a snug margin.")
        }
    }

    // MARK: - Writing

    private func update(_ change: (inout TypographySettings) -> Void) {
        var next = typography
        change(&next)
        guard next != typography else { return }
        settings.setTypography(next, for: bookID)
    }
}

// MARK: - Sample

/// A few lines of public-domain prose set the way the book will be: the
/// theme's page and ink, the font, its relative size, spacing and margin.
/// Clipped to a fixed height so the sheet doesn't jump as the size changes.
private struct TypographySample: View {
    let settings: TypographySettings

    @ScaledMetric(relativeTo: .body) private var baseSize: CGFloat = 16

    private static let text = "It is a truth universally acknowledged, that a single man in possession of a good fortune, must be in want of a wife."

    var body: some View {
        let size = baseSize * settings.fontScale
        let lineHeight = settings.lineHeight ?? 1.3
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Text(Self.text)
            .font(TypographyFontRegistry.previewFont(settings.font, size: size))
            .lineSpacing(max(0, (lineHeight - 1.15) * size))
            .multilineTextAlignment(.leading)
            .foregroundStyle(settings.effectiveTextColor.swiftUIColor)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            // The page gutter is 20 pt × the margin factor on a phone; the
            // sample is a little narrower than a page, so scale it down a touch.
            .padding(.horizontal, 20 * settings.pageMargins * 0.8)
            .padding(.vertical, 14)
            .frame(height: 132, alignment: .topLeading)
            .clipped()
            .background(settings.backgroundColor.swiftUIColor, in: shape)
            .overlay(shape.strokeBorder(.primary.opacity(0.08)))
            .animation(.easeInOut(duration: 0.2), value: settings)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sample text")
            .accessibilityValue(
                "\(settings.font.displayName), \(Int((settings.fontScale * 100).rounded())) percent, \(settings.theme.displayName) theme"
            )
            .accessibilityIdentifier("typography-sample")
    }
}

// MARK: - Stepped slider

/// A slider that snaps to a list of stops (which need not be evenly spaced).
private struct SteppedSlider<MinLabel: View, MaxLabel: View>: View {
    let steps: [Double]
    let value: Double
    let title: String
    let valueDescription: (Double) -> String
    @ViewBuilder let minimumLabel: () -> MinLabel
    @ViewBuilder let maximumLabel: () -> MaxLabel
    let onChange: (Double) -> Void

    private var index: Int {
        steps.indices.min { abs(steps[$0] - value) < abs(steps[$1] - value) } ?? 0
    }

    private var position: Binding<Double> {
        Binding<Double>(
            get: { Double(index) },
            set: { (raw: Double) in
                let i: Int = Swift.min(Swift.max(Int(raw.rounded()), 0), steps.count - 1)
                if i != index { onChange(steps[i]) }
            }
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            minimumLabel()
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(value: position, in: 0...Double(Swift.max(steps.count - 1, 1)), step: 1)
                .accessibilityLabel(Text(title))
                .accessibilityValue(Text(valueDescription(steps[index])))
            maximumLabel()
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Theme swatch

private struct ThemeSwatch: View {
    let theme: TypographyTheme
    let isSelected: Bool
    let action: () -> Void

    @ScaledMetric(relativeTo: .body) private var diameter: CGFloat = 46

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(theme.backgroundColor.swiftUIColor)
                    Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 1)
                    Text("Aa")
                        .font(.system(.callout, design: .serif).weight(.medium))
                        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                        .foregroundStyle(theme.textColor.swiftUIColor)
                }
                // Capped: four swatches must fit a narrow cover screen even at
                // accessibility text sizes.
                .frame(width: min(diameter, 52), height: min(diameter, 52))
                .padding(3)
                .overlay {
                    if isSelected { Circle().strokeBorder(Color.accentColor, lineWidth: 2.5) }
                }
                Text(theme.displayName)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(theme.displayName) theme")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("typography-theme-\(theme.rawValue)")
    }
}

// MARK: - Ink

/// Text colour: the theme's own ink, a few curated inks, or any colour.
private struct InkRow: View {
    let theme: TypographyTheme
    let customColor: RGBAColor?
    let onChange: (RGBAColor?) -> Void

    @ScaledMetric(relativeTo: .body) private var dot: CGFloat = 26

    /// Dark inks suit the light pages, light ones the dark pages.
    private var inks: [(name: String, color: RGBAColor)] {
        theme.isDark
            ? [("Bone", RGBAColor(hex: 0xE8E2D4)), ("Amber", RGBAColor(hex: 0xE3B266)),
               ("Sage", RGBAColor(hex: 0xB5C9A8)), ("Mist", RGBAColor(hex: 0xA9B8CC))]
            : [("Ink", RGBAColor(hex: 0x111111)), ("Navy", RGBAColor(hex: 0x1D2B4A)),
               ("Forest", RGBAColor(hex: 0x1E3A28)), ("Oxblood", RGBAColor(hex: 0x5B1A18))]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Text colour")
            HStack(spacing: 10) {
                inkDot(name: "\(theme.displayName) ink", color: theme.textColor, selected: customColor == nil) {
                    onChange(nil)
                }
                ForEach(inks, id: \.name) { ink in
                    inkDot(name: ink.name, color: ink.color, selected: customColor == ink.color) {
                        onChange(ink.color)
                    }
                }
                ColorPicker(
                    "Custom text colour",
                    selection: Binding(
                        get: { (customColor ?? theme.textColor).swiftUIColor },
                        set: { onChange(RGBAColor(swiftUIColor: $0)) }
                    ),
                    supportsOpacity: false
                )
                .labelsHidden()
                .accessibilityIdentifier("typography-ink-custom")
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 2)
    }

    private func inkDot(name: String, color: RGBAColor, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(color.swiftUIColor)
                .overlay(Circle().strokeBorder(.primary.opacity(0.2), lineWidth: 1))
                .frame(width: min(dot, 32), height: min(dot, 32))
                .padding(2)
                .overlay { if selected { Circle().strokeBorder(Color.accentColor, lineWidth: 2) } }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ContrastNote: View {
    let ratio: Double

    private var passes: Bool { ratio >= ColorContrast.aaMinimum }
    private var ratioText: String { String(format: "%.1f:1", ratio) }

    var body: some View {
        Label {
            Text(passes
                 ? "Contrast \(ratioText). Comfortable to read."
                 : "Low contrast (\(ratioText)). Body text needs at least 4.5:1 to be easy to read.")
                .font(.footnote)
        } icon: {
            Image(systemName: passes ? "checkmark.circle" : "exclamationmark.triangle.fill")
                .foregroundStyle(passes ? Color.secondary : Color.orange)
        }
        .foregroundStyle(passes ? .secondary : .primary)
        .accessibilityIdentifier("typography-contrast")
    }
}

// MARK: - Fonts in the app's own UI

enum TypographyFontRegistry {

    /// OpenDyslexic ships inside Readium's navigator resource bundle for the
    /// web view; registering it for this process lets the panel preview it
    /// too. Does nothing if the file is not there.
    @MainActor static func registerBundledFonts() {
        guard !didRegister else { return }
        didRegister = true
        guard UIFont(name: "OpenDyslexic-Regular", size: 12) == nil else { return }
        let resources = Bundle.main.bundleURL
        let enumerator = FileManager.default.enumerator(at: resources, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == "OpenDyslexic-Regular.otf" {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
                return
            }
        }
    }

    @MainActor private static var didRegister = false

    /// The font at a Dynamic Type text style, for the font list.
    static func previewFont(_ font: TypographyFont, textStyle: Font.TextStyle) -> Font {
        switch font {
        case .publisher: return .system(textStyle)
        case .newYork: return .system(textStyle, design: .serif)
        case .sfPro: return .system(textStyle)
        default:
            let size = UIFont.preferredFont(forTextStyle: uiTextStyle(textStyle)).pointSize
            return custom(font, size: size, relativeTo: textStyle)
        }
    }

    /// The font at an explicit size, for the sample.
    static func previewFont(_ font: TypographyFont, size: CGFloat) -> Font {
        switch font {
        case .publisher, .newYork: return .system(size: size, design: .serif)
        case .sfPro: return .system(size: size)
        default: return custom(font, size: size, relativeTo: nil)
        }
    }

    private static func custom(_ font: TypographyFont, size: CGFloat, relativeTo style: Font.TextStyle?) -> Font {
        guard let name = font.previewPostScriptName, UIFont(name: name, size: size) != nil else {
            return .system(size: size)
        }
        if let style { return .custom(name, size: size, relativeTo: style) }
        return .custom(name, fixedSize: size)
    }

    private static func uiTextStyle(_ style: Font.TextStyle) -> UIFont.TextStyle {
        switch style {
        case .caption: return .caption1
        case .footnote: return .footnote
        case .headline: return .headline
        case .title3: return .title3
        default: return .body
        }
    }
}

private extension RGBAColor {
    init(swiftUIColor color: Color) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(Double(r).clamped(to: 0...1), Double(g).clamped(to: 0...1), Double(b).clamped(to: 0...1), 1)
    }
}
