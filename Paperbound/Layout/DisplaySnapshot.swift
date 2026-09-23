//
//  DisplaySnapshot.swift
//  Paperbound
//
//  What the app can actually learn about the display it is sitting on.
//
//  On the iPhone Duo this is the whole game. The device reports two integrated
//  displays — a smaller cover screen and a larger inner screen — and folding or
//  unfolding moves the app's scene from one to the other. There is no hinge
//  angle to read (see DeviceLayoutCoordinator for what was actually checked in
//  the SDK), but *which screen the scene is on* is public, current API and it
//  is a far better signal than guessing from the window's aspect ratio.
//
//  Everything here uses APIs that are not deprecated in iOS 27:
//  `UIApplication.connectedScenes`, `UIWindowScene.screen`, `UIWindowScene.keyWindow`.
//  `UIScreen.screens` and `UIScreen.main` are deliberately not used.
//

import Foundation
import Observation
import SwiftUI
import UIKit

struct DisplaySnapshot: Equatable, Sendable {

    /// The whole display, in points.
    var screenSize: CGSize
    /// Our scene's window, in points. On the Duo's cover screen this is
    /// narrower than the display, because the system reserves a strip.
    var windowSize: CGSize
    /// The regions the window must keep clear.
    var safeAreaInsets: UIEdgeInsets
    var scale: CGFloat

    /// How many distinct displays this session has seen the scene live on.
    /// Two or more is proof the device folds.
    var distinctScreensSeen: Int
    /// True when the current screen is the largest one seen so far.
    var isOnLargestSeenScreen: Bool
    /// Area of the largest display seen, for describing the fold to the reader.
    var largestSeenScreenSize: CGSize

    static let unknown = DisplaySnapshot(
        screenSize: .zero,
        windowSize: .zero,
        safeAreaInsets: .zero,
        scale: 1,
        distinctScreensSeen: 0,
        isOnLargestSeenScreen: true,
        largestSeenScreenSize: .zero
    )

    var isUsable: Bool { screenSize.width > 0 && screenSize.height > 0 }

    /// The device has demonstrably more than one display, so posture is a fact
    /// rather than an inference.
    var hasMultipleDisplays: Bool { distinctScreensSeen > 1 }

    /// The window does not cover the whole display — a reserved strip, a
    /// sensor bar, or a partial-width scene.
    var windowIsInsetFromScreen: Bool {
        guard isUsable, windowSize.width > 0 else { return false }
        return (screenSize.width - windowSize.width) > 1
            || (screenSize.height - windowSize.height) > 1
    }

    /// Short description for the reader-facing posture row.
    var displayDescription: String {
        guard isUsable else { return "unknown display" }
        let w = Int(screenSize.width.rounded())
        let h = Int(screenSize.height.rounded())
        if hasMultipleDisplays {
            return isOnLargestSeenScreen ? "inner display \(w)×\(h)" : "cover display \(w)×\(h)"
        }
        return "display \(w)×\(h)"
    }
}

@MainActor
@Observable
final class DisplayObserver {

    private(set) var snapshot: DisplaySnapshot = .unknown

    /// Sizes of every display the scene has been seen on, normalised so that a
    /// rotation is not mistaken for a different screen.
    private var seenScreens: Set<ScreenKey> = []

    /// A display identified by its point dimensions, orientation-independent.
    private struct ScreenKey: Hashable {
        let shortSide: Int
        let longSide: Int

        init(_ size: CGSize) {
            let a = Int(size.width.rounded())
            let b = Int(size.height.rounded())
            shortSide = min(a, b)
            longSide = max(a, b)
        }

        var area: Int { shortSide * longSide }
    }

    /// Re-reads the display. Cheap enough to call on every layout change, which
    /// is exactly when a fold shows up.
    func refresh() {
        guard let scene = Self.activeWindowScene() else { return }

        let screenSize = scene.screen.bounds.size
        guard screenSize.width > 0, screenSize.height > 0 else { return }

        let window = scene.keyWindow
        let windowSize = window?.bounds.size ?? screenSize
        let insets = window?.safeAreaInsets ?? .zero
        let scale = scene.screen.scale

        let key = ScreenKey(screenSize)
        seenScreens.insert(key)

        let largest = seenScreens.max(by: { $0.area < $1.area }) ?? key
        let largestSize = CGSize(width: largest.shortSide, height: largest.longSide)

        let next = DisplaySnapshot(
            screenSize: screenSize,
            windowSize: windowSize,
            safeAreaInsets: insets,
            scale: scale,
            distinctScreensSeen: seenScreens.count,
            isOnLargestSeenScreen: key.area >= largest.area,
            largestSeenScreenSize: largestSize
        )

        if next != snapshot {
            snapshot = next
        }
    }

    /// Forgets the display history. Only for tests — a real session should keep
    /// accumulating evidence that the device folds.
    func resetHistory() {
        seenScreens.removeAll()
        snapshot = .unknown
    }

    private static func activeWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
            ?? scenes.first
    }
}
