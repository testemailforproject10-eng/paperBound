//
//  RGBAColor.swift
//  Paperbound
//
//  A UIKit-free colour value so that model types (environments, damage
//  descriptors) stay portable and Codable. Rendering code converts to
//  CGColor / SwiftUI Color at the edges.
//

import CoreGraphics
import SwiftUI

struct RGBAColor: Codable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Convenience for 8-bit literals, e.g. `RGBAColor(hex: 0xE8DFC8)`.
    init(hex: UInt32, alpha: Double = 1.0) {
        self.red = Double((hex >> 16) & 0xFF) / 255.0
        self.green = Double((hex >> 8) & 0xFF) / 255.0
        self.blue = Double(hex & 0xFF) / 255.0
        self.alpha = alpha
    }

    func withAlpha(_ newAlpha: Double) -> RGBAColor {
        RGBAColor(red, green, blue, newAlpha)
    }

    /// Multiplies the RGB channels, keeping alpha. Used for under-sheet shading.
    func scaled(by factor: Double) -> RGBAColor {
        RGBAColor(
            (red * factor).clamped(to: 0...1),
            (green * factor).clamped(to: 0...1),
            (blue * factor).clamped(to: 0...1),
            alpha
        )
    }

    /// Linear blend towards another colour. `t == 0` returns self.
    func blended(with other: RGBAColor, amount t: Double) -> RGBAColor {
        let k = t.clamped(to: 0...1)
        return RGBAColor(
            red + (other.red - red) * k,
            green + (other.green - green) * k,
            blue + (other.blue - blue) * k,
            alpha + (other.alpha - alpha) * k
        )
    }

    /// Perceived luminance, used to decide whether ink should be inverted.
    var luminance: Double {
        0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    var cgColor: CGColor {
        CGColor(
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            components: [CGFloat(red), CGFloat(green), CGFloat(blue), CGFloat(alpha)]
        ) ?? CGColor(gray: CGFloat(luminance), alpha: CGFloat(alpha))
    }

    var swiftUIColor: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}

extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
