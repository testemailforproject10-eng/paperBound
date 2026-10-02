//
//  HighlightActionBar.swift
//  Paperbound
//
//  The floating card shown next to a text selection: pick how the mark is
//  drawn (style), its colour, and act on the selection (copy, delete).
//  Picking a style or colour on a selection is what marks it. The view owns no annotation state; it only reflects `style`,
//  `color` and `mode` and reports taps through its callbacks.
//
//  Regular layout, three rows on one 18pt card:
//      [ Aa  Aa  Aa  Aa ]        style previews drawn in the current colour
//      (  ) (  ) (  ) (  ) (  )  colour swatches
//      [ Copy ]                  actions (Delete or Clear joins Copy when
//                                there is a mark to remove)
//
//  Compact layout, one row for narrow surfaces such as the cover screen:
//      (  )(  )(  )(  )(  ) | Aa v | copy | delete-or-clear (copy fills both
//                                               when there is nothing to remove)
//

import SwiftUI

struct HighlightActionBar: View {
    enum Mode: Sendable { case create, edit }

    let mode: Mode
    let style: HighlightStyle
    let color: HighlightColor
    /// Single-row layout for narrow surfaces (cover screen, small panels).
    var compact: Bool = false
    var onStyle: (HighlightStyle) -> Void
    var onColor: (HighlightColor) -> Void
    /// Styles and colours already on the text: the open mark's, or every
    /// mark under the selection. They show as chosen; tapping one again
    /// removes it.
    let chosenStyles: Set<HighlightStyle>
    let chosenColors: Set<HighlightColor>
    var onCopy: () -> Void
    /// Edit mode: delete the open mark. Create mode: clear every mark under
    /// the selection, offered only when there is one.
    var onDelete: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.highlightActionBarOpaqueSurface) private var forceOpaqueSurface
    @Environment(\.colorScheme) private var colorScheme
    @State private var copyCount = 0
    @State private var showsCopied = false

    init(
        mode: Mode,
        style: HighlightStyle,
        color: HighlightColor,
        compact: Bool = false,
        chosenStyles: Set<HighlightStyle>? = nil,
        chosenColors: Set<HighlightColor>? = nil,
        onStyle: @escaping (HighlightStyle) -> Void,
        onColor: @escaping (HighlightColor) -> Void,
        onCopy: @escaping () -> Void,
        onDelete: (() -> Void)? = nil
    ) {
        self.mode = mode
        self.style = style
        self.color = color
        self.compact = compact
        self.chosenStyles = chosenStyles ?? (mode == .edit ? [style] : [])
        self.chosenColors = chosenColors ?? (mode == .edit ? [color] : [])
        self.onStyle = onStyle
        self.onColor = onColor
        self.onCopy = onCopy
        self.onDelete = onDelete
    }

    /// Natural size of the bar, for placement before it is laid out.
    static func preferredSize(compact: Bool) -> CGSize {
        compact ? Metrics.compactSize : Metrics.regularSize
    }

    /// The insertion and removal transition: a quick springy scale from 0.96
    /// plus a fade, growing out of the selection side. Fade only with Reduce Motion.
    /// Pair it with `appearAnimation(reduceMotion:)`.
    static func transition(isAbove: Bool, reduceMotion: Bool) -> AnyTransition {
        if reduceMotion { return .opacity }
        return .scale(scale: 0.96, anchor: isAbove ? .bottom : .top).combined(with: .opacity)
    }

    /// The animation to wrap the bar's insertion and removal in.
    static func appearAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.18) : .spring(response: 0.26, dampingFraction: 0.78)
    }

    var body: some View {
        Group {
            if compact { compactBody } else { regularBody }
        }
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .background { card }
        .compositingGroup()
        .shadow(color: shadowTint, radius: 14, x: 0, y: 6)
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.10), radius: 2, x: 0, y: 1)
        .animation(changeAnimation, value: style)
        .animation(changeAnimation, value: color)
        .animation(changeAnimation, value: mode)
        .sensoryFeedback(.selection, trigger: style)
        .sensoryFeedback(.selection, trigger: color)
        .sensoryFeedback(.success, trigger: copyCount)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(mode == .create ? "Selection actions" : "Mark actions")
        .accessibilityIdentifier("highlight-action-bar")
    }

    // MARK: - Card

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
        let opaque = reduceTransparency || forceOpaqueSurface
        return ZStack {
            if opaque {
                shape.fill(colorScheme == .dark
                    ? Color(.sRGB, red: 0.165, green: 0.16, blue: 0.17, opacity: 1)
                    : Color(.sRGB, red: 0.995, green: 0.99, blue: 0.98, opacity: 1))
            } else {
                shape.fill(.regularMaterial)
            }
        }
        .overlay {
            shape.strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.09), lineWidth: 0.75)
        }
    }

    private var shadowTint: Color {
        let base = color.actionBarSolid
        return colorScheme == .dark
            ? Color.black.opacity(0.45)
            : Color(.sRGB, red: base.red * 0.55, green: base.green * 0.5, blue: base.blue * 0.45, opacity: 0.22)
    }

    private var changeAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .snappy(duration: 0.24)
    }

    // MARK: - Regular

    private var regularBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: Metrics.tileSpacing) {
                ForEach(HighlightStyle.allCases) { option in
                    styleTile(option)
                }
            }
            .frame(height: Metrics.target)

            HStack(spacing: 0) {
                ForEach(HighlightColor.allCases) { option in
                    swatch(option)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: Metrics.target)
            .padding(.top, Metrics.rowSpacing)

            Rectangle()
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.08))
                .frame(height: Metrics.hairline)
                .padding(.vertical, Metrics.sectionGap)

            actionsRow
                .frame(height: Metrics.target)
        }
        .padding(Metrics.padding)
        .frame(width: Metrics.regularSize.width, height: Metrics.regularSize.height)
    }

    /// Only marks already on the text show as chosen; `style` and `color`
    /// otherwise just tint the previews.
    private func isChosen(_ option: HighlightStyle) -> Bool { chosenStyles.contains(option) }
    private func isChosen(_ option: HighlightColor) -> Bool { chosenColors.contains(option) }

    private var deleteTitle: String { mode == .edit ? "Delete" : "Clear" }
    private var deleteSymbol: String { mode == .edit ? "trash" : "eraser" }

    private func styleTile(_ option: HighlightStyle) -> some View {
        let selected = isChosen(option)
        let shape = RoundedRectangle(cornerRadius: Metrics.innerRadius, style: .continuous)
        return Button {
            onStyle(option)
        } label: {
            HighlightStyleGlyph(style: option, color: color, fontSize: 19)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    shape.fill(Color.primary.opacity(selected ? (colorScheme == .dark ? 0.16 : 0.08) : 0))
                }
                .overlay {
                    shape.strokeBorder(Color.primary.opacity(selected ? 0.28 : 0), lineWidth: 1)
                }
                .contentShape(shape)
        }
        .buttonStyle(PressableStyle())
        .frame(maxWidth: .infinity, minHeight: Metrics.target)
        .accessibilityLabel(option.title)
        .accessibilityHint(selected ? "Removes this style" : mode == .create ? "Marks the selection with this style" : "Changes the mark to this style")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("highlight-bar.style.\(option.rawValue)")
    }

    private func swatch(_ option: HighlightColor) -> some View {
        let selected = isChosen(option)
        let solid = option.actionBarSolid
        return Button {
            onColor(option)
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(Color.primary.opacity(selected ? 0.75 : 0), lineWidth: 2)
                    .frame(width: Metrics.swatchRing, height: Metrics.swatchRing)
                Circle()
                    .fill(solid.swiftUIColor)
                    .overlay { Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5) }
                    .frame(width: Metrics.swatchDiameter, height: Metrics.swatchDiameter)
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(solid.actionBarLabelColor)
                    .opacity(selected ? 1 : 0)
                    .scaleEffect(selected ? 1 : 0.5)
            }
            .frame(width: Metrics.target, height: Metrics.target)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(option.displayName)
        .accessibilityHint(mode == .create ? "Marks the selection in this colour" : "Changes the mark to this colour")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("highlight-bar.color.\(option.rawValue)")
    }

    // MARK: - Actions

    /// One entry per action, in display order. Later phases (Note, Dictionary,
    /// More) are added here; the row adapts its layout to the count.
    private var actions: [BarAction] {
        var list: [BarAction] = []
        if let onDelete {
            list.append(BarAction(id: "delete", title: deleteTitle, systemImage: deleteSymbol,
                                  role: .destructive, perform: onDelete))
        }
        list.append(BarAction(
            id: "copy",
            title: showsCopied ? "Copied" : "Copy",
            systemImage: showsCopied ? "checkmark" : "doc.on.doc",
            role: .standard,
            perform: copy
        ))
        return list
    }

    private var actionsRow: some View {
        let items = actions
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: Metrics.tileSpacing) {
                ForEach(items) { actionButton($0, stacked: false) }
            }
            HStack(spacing: Metrics.tileSpacing) {
                ForEach(items) { actionButton($0, stacked: true) }
            }
        }
    }

    private func actionButton(_ action: BarAction, stacked: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.innerRadius, style: .continuous)
        let palette = actionPalette(action.role)
        return Button(action: action.perform) {
            Group {
                if stacked {
                    VStack(spacing: 2) {
                        Image(systemName: action.systemImage).font(.system(size: 15, weight: .semibold))
                        Text(action.title).font(.caption2.weight(.semibold))
                    }
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: action.systemImage).font(.system(size: 14, weight: .semibold))
                        Text(action.title).font(.subheadline.weight(.semibold))
                    }
                }
            }
            .lineLimit(1)
            .fixedSize()
            .contentTransition(.symbolEffect(.replace))
            .foregroundStyle(palette.foreground)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { shape.fill(palette.background) }
            .contentShape(shape)
        }
        .buttonStyle(PressableStyle())
        .frame(minWidth: Metrics.target, maxWidth: .infinity, minHeight: Metrics.target)
        .accessibilityLabel(action.title)
        .accessibilityIdentifier("highlight-bar.action.\(action.id)")
    }

    private func actionPalette(_ role: BarAction.Role) -> (foreground: Color, background: Color) {
        let dark = colorScheme == .dark
        switch role {
        case .standard:
            return (.primary, Color.primary.opacity(dark ? 0.12 : 0.06))
        case .destructive:
            return (Color.red, Color.red.opacity(dark ? 0.2 : 0.1))
        }
    }

    private func copy() {
        onCopy()
        copyCount += 1
        showsCopied = true
        let tick = copyCount
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            if tick == copyCount { showsCopied = false }
        }
    }

    // MARK: - Compact

    private var compactBody: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(HighlightColor.allCases) { option in
                    compactSwatch(option)
                }
            }
            styleMenu
                .overlay(alignment: .leading) { compactDivider }
            compactIconButton(
                id: "copy",
                title: showsCopied ? "Copied" : "Copy",
                systemImage: showsCopied ? "checkmark" : "doc.on.doc",
                role: .standard,
                width: onDelete != nil ? Metrics.target : Metrics.target * 2,
                perform: copy
            )
            .overlay(alignment: .leading) { compactDivider }
            if let onDelete {
                compactIconButton(id: "delete", title: deleteTitle, systemImage: deleteSymbol,
                                  role: .destructive, perform: onDelete)
            }
        }
        .padding(.horizontal, Metrics.compactPadding)
        .padding(.vertical, Metrics.compactPadding)
        .frame(width: Metrics.compactSize.width, height: Metrics.compactSize.height)
    }

    private var compactDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.1))
            .frame(width: Metrics.hairline, height: 22)
            .offset(x: -Metrics.hairline / 2)
            .accessibilityHidden(true)
    }

    private func compactSwatch(_ option: HighlightColor) -> some View {
        let selected = isChosen(option)
        let solid = option.actionBarSolid
        return Button {
            onColor(option)
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(Color.primary.opacity(selected ? 0.75 : 0), lineWidth: 2)
                    .frame(width: Metrics.compactSwatchRing, height: Metrics.compactSwatchRing)
                Circle()
                    .fill(solid.swiftUIColor)
                    .overlay { Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5) }
                    .frame(width: Metrics.compactSwatchDiameter, height: Metrics.compactSwatchDiameter)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(solid.actionBarLabelColor)
                    .opacity(selected ? 1 : 0)
                    .scaleEffect(selected ? 1 : 0.5)
            }
            .frame(width: Metrics.compactSwatchWidth, height: Metrics.target)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(option.displayName)
        .accessibilityHint(mode == .create ? "Marks the selection in this colour" : "Changes the mark to this colour")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("highlight-bar.color.\(option.rawValue)")
    }

    private var styleMenu: some View {
        Menu {
            // Toggles, not a picker: the text can carry several styles at
            // once, or none, and choosing a checked one removes it.
            ForEach(HighlightStyle.allCases) { option in
                Toggle(isOn: Binding(get: { isChosen(option) }, set: { _ in onStyle(option) })) {
                    Label(option.title, systemImage: option.systemImage)
                }
            }
        } label: {
            HighlightStyleMenuLabel(style: style, color: color)
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Style")
        .accessibilityValue(HighlightStyle.allCases.filter(isChosen).map(\.title).joined(separator: ", "))
        .accessibilityIdentifier("highlight-bar.style-menu")
    }

    private func compactIconButton(
        id: String, title: String, systemImage: String, role: BarAction.Role,
        width: CGFloat = Metrics.target, perform: @escaping () -> Void
    ) -> some View {
        let palette = actionPalette(role)
        let shape = RoundedRectangle(cornerRadius: Metrics.innerRadius, style: .continuous)
        return Button(action: perform) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(palette.foreground)
                .frame(width: width, height: Metrics.target)
                .background {
                    if role != .standard { shape.fill(palette.background) }
                }
                .contentShape(shape)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(title)
        .accessibilityIdentifier("highlight-bar.action.\(id)")
    }
}

// MARK: - Surface

extension EnvironmentValues {
    /// Draws the bar on an opaque surface instead of the system material. The
    /// bar already does this when Reduce Transparency is on; set it where a
    /// material cannot render (snapshots via `ImageRenderer`) or is unwanted.
    @Entry var highlightActionBarOpaqueSurface: Bool = false
}

// MARK: - Metrics

extension HighlightActionBar {
    /// One radius system: 18pt card, 12pt inner controls, fully round swatches.
    enum Metrics {
        static let cardRadius: CGFloat = 18
        static let innerRadius: CGFloat = 12
        static let target: CGFloat = 44
        static let padding: CGFloat = 10
        static let rowSpacing: CGFloat = 2
        static let sectionGap: CGFloat = 6
        static let tileSpacing: CGFloat = 6
        static let hairline: CGFloat = 1
        static let swatchDiameter: CGFloat = 30
        static let compactSwatchDiameter: CGFloat = 28
        static let swatchRing: CGFloat = 38

        static let regularWidth: CGFloat = 296
        static var regularSize: CGSize {
            let height = padding * 2 + target * 3 + rowSpacing + sectionGap * 2 + hairline
            return CGSize(width: regularWidth, height: height)
        }

        static let compactPadding: CGFloat = 4
        static let compactMenuWidth: CGFloat = 44
        static let compactSwatchRing: CGFloat = 36
        /// Swatch targets in the single row are 40pt wide and 44pt tall: five at
        /// 44pt plus three 44pt controls cannot fit 340pt. Every other control is 44x44.
        static let compactSwatchWidth: CGFloat = 40
        /// Five swatches, the style menu, Copy and Delete (Copy takes both
        /// slots when there is nothing to delete); the dividers are overlays and take no width. 340 x 52.
        static var compactSize: CGSize {
            let width = compactPadding * 2 + compactSwatchWidth * 5 + compactMenuWidth + target * 2
            return CGSize(width: width, height: target + compactPadding * 2)
        }
    }
}

// MARK: - Action model

/// An entry in the bar's actions row.
struct BarAction: Identifiable {
    enum Role { case standard, destructive }
    let id: String
    let title: String
    let systemImage: String
    let role: Role
    let perform: () -> Void
}

// MARK: - Style preview glyph

/// "Aa" drawn the way a mark of `style` in `color` will look on the page.
struct HighlightStyleGlyph: View {
    let style: HighlightStyle
    let color: HighlightColor
    var fontSize: CGFloat = 17
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let solid = color.actionBarSolid
        // Thin lines need a deeper tone on light surfaces and the bright one on dark.
        let ink = colorScheme == .dark ? solid : solid.actionBarInk
        let line = max(1.5, fontSize / 10)
        Text("Aa")
            .font(.system(size: fontSize, weight: .medium, design: .serif))
            .foregroundStyle(style == .highlight ? AnyShapeStyle(solid.actionBarLabelColor) : AnyShapeStyle(.primary))
            .padding(.horizontal, fontSize * 0.18)
            .padding(.vertical, fontSize * 0.04)
            .background {
                if style == .highlight {
                    RoundedRectangle(cornerRadius: fontSize * 0.2, style: .continuous)
                        .fill(solid.swiftUIColor.opacity(colorScheme == .dark ? 0.92 : 0.75))
                }
            }
            .overlay(alignment: .bottom) {
                switch style {
                case .underline:
                    Capsule().fill(ink.swiftUIColor)
                        .frame(height: line)
                        .padding(.horizontal, fontSize * 0.12)
                        .offset(y: -fontSize * 0.08)
                case .squiggly:
                    SquiggleShape(wavelength: fontSize * 0.36)
                        .stroke(ink.swiftUIColor, style: StrokeStyle(lineWidth: line * 0.9, lineCap: .round, lineJoin: .round))
                        .frame(height: fontSize * 0.22)
                        .padding(.horizontal, fontSize * 0.12)
                        .offset(y: fontSize * 0.02)
                case .highlight, .strikethrough:
                    EmptyView()
                }
            }
            .overlay {
                if style == .strikethrough {
                    Capsule().fill(ink.swiftUIColor)
                        .frame(height: line)
                        .padding(.horizontal, fontSize * 0.08)
                        .offset(y: fontSize * 0.06)
                }
            }
            .accessibilityHidden(true)
    }
}

/// The compact bar's style menu button: the current style's preview and a chevron.
struct HighlightStyleMenuLabel: View {
    let style: HighlightStyle
    let color: HighlightColor

    var body: some View {
        HStack(spacing: 2) {
            HighlightStyleGlyph(style: style, color: color, fontSize: 16)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .frame(width: HighlightActionBar.Metrics.compactMenuWidth, height: HighlightActionBar.Metrics.target)
        .contentShape(Rectangle())
    }
}

/// A gentle sine wave across the rect, for the squiggly underline.
struct SquiggleShape: Shape {
    var wavelength: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let amplitude = rect.height / 2
        let midY = rect.midY
        let step = max(0.5, wavelength / 12)
        path.move(to: CGPoint(x: rect.minX, y: midY))
        var x = rect.minX
        while x < rect.maxX {
            x = min(rect.maxX, x + step)
            let phase = (x - rect.minX) / max(1, wavelength) * 2 * .pi
            path.addLine(to: CGPoint(x: x, y: midY - sin(phase) * amplitude))
        }
        return path
    }
}

// MARK: - Press feedback

/// Dims and slightly shrinks a control while pressed; no system chrome.
private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Colour helpers

extension HighlightColor {
    /// The mark colour at full opacity, for swatches and style previews.
    var actionBarSolid: RGBAColor { color.withAlpha(1) }
}

extension RGBAColor {
    /// WCAG relative luminance of the opaque colour.
    var actionBarRelativeLuminance: Double {
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// True when near-black text has more contrast on this colour than white.
    var actionBarPrefersDarkLabel: Bool {
        let l = actionBarRelativeLuminance
        let onBlack = (l + 0.05) / 0.05
        let onWhite = 1.05 / (l + 0.05)
        return onBlack >= onWhite
    }

    /// Label colour for text or glyphs drawn on this colour.
    var actionBarLabelColor: Color {
        actionBarPrefersDarkLabel ? Color(.sRGB, red: 0.1, green: 0.09, blue: 0.08, opacity: 1) : .white
    }

    /// A deeper tone of the colour for thin lines (underline, strike, squiggle),
    /// so pale hues such as butter stay visible next to text.
    var actionBarInk: RGBAColor {
        scaled(by: 0.78).withAlpha(1)
    }
}
