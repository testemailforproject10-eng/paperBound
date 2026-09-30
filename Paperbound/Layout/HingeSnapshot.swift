//
//  HingeSnapshot.swift
//  Paperbound
//
//  What the app can learn from the hinge itself.
//
//  iOS 27.1 adds UIKit's `UIHingeInteraction` and SwiftUI's `onHingeChange`.
//  The selected 27.1 SDK declares both APIs. This reader retains its existing
//  UIKit integration because the interaction provides the hinge updates this
//  observer already consumes:
//
//      UIHinge.status   closed · partiallyOpen · fullyOpen · unknown
//      UIHinge.angle    radians
//
//  This is strictly better evidence than watching which display the scene is
//  on. Display identity needs the device to have *already* been folded once
//  before it can claim anything; the hinge reports on the first update. It is
//  also the only way to see the partly-open posture at all — a display can
//  only ever say cover or inner.
//
//  Deployment target is iOS 18, so every use is behind `#available`, and
//  `DisplayPostureProvider` remains the fallback for:
//    * iOS 18 … 27.0, where the API does not exist,
//    * every device without a hinge, where it reports nothing,
//    * `.unknown`, where the system declines to say.
//
//  The angle is documented as system policy — "don't depend on a particular
//  update frequency or precision" — so it drives shading only. Every layout
//  decision is made from `status`.
//

import Foundation
import Observation
import SwiftUI
import UIKit

// MARK: - Snapshot

struct HingeSnapshot: Equatable, Sendable {

    /// Mirrors `UIHinge.Status`, plus the case the enum cannot express: this
    /// build or this device has no hinge to report on.
    enum Status: String, Equatable, Sendable {
        /// No hinge API (pre-27.1), or no hinge on this device.
        case unavailable
        /// There is a hinge, and the system declines to say where it is.
        case unknown
        case closed
        case partiallyOpen
        case fullyOpen
    }

    var status: Status
    /// Radians, as reported. Zero whenever `status` is not a reported one.
    var angle: Double

    static let unavailable = HingeSnapshot(status: .unavailable, angle: 0)

    /// True only when the hinge actually told us where it is.
    var isReported: Bool {
        switch status {
        case .unavailable, .unknown: return false
        case .closed, .partiallyOpen, .fullyOpen: return true
        }
    }

    /// How far open the device is: 0 shut, 1 pressed flat.
    ///
    /// A hinge that opens to 180° is flat, so the angle is measured against
    /// `.pi`. Anything past flat — or any angle the system reports while it is
    /// still settling — clamps rather than running off the end of the range.
    var openness: Double {
        guard isReported else { return 0 }
        if status == .closed { return 0 }
        return min(max(angle / .pi, 0), 1)
    }

    /// Short description for the reader-facing posture row, which never claims
    /// more than the hinge said.
    var description: String {
        switch status {
        case .unavailable: return "no hinge"
        case .unknown: return "hinge, position unknown"
        case .closed: return "hinge closed"
        case .partiallyOpen: return "hinge \(degrees)° open"
        case .fullyOpen: return "hinge fully open"
        }
    }

    private var degrees: Int {
        Int((angle * 180 / .pi).rounded())
    }
}

// MARK: - Observer

/// Owns the `UIHingeInteraction` and republishes it as a plain value.
///
/// Attach `HingeObservationView` somewhere in the hierarchy to feed it. Until
/// something does, the snapshot stays `.unavailable` and every posture decision
/// falls through to display observation, which is exactly the behaviour on
/// every build and device without a hinge.
@MainActor
@Observable
final class HingeObserver {

    private(set) var snapshot: HingeSnapshot = .unavailable

    /// Held so the interaction outlives the view that installed it being laid
    /// out again. `UIHingeInteraction` stores and escapes its handler, so the
    /// handler must not capture this object strongly.
    @ObservationIgnored private var interaction: AnyObject?

    /// True when this build can see the API at all, whatever the device says.
    static var isSupported: Bool {
        if #available(iOS 27.1, *) { return true }
        return false
    }

    /// Builds the interaction to install on a host view, or nil before 27.1.
    func makeInteraction() -> UIInteraction? {
        guard #available(iOS 27.1, *) else { return nil }

        let created = UIHingeInteraction { [weak self] _, update in
            guard let self else { return }
            // A nil hinge means the interaction left a hierarchy that provides
            // hinge updates — not that the device closed.
            guard let hinge = update.hinge else {
                self.apply(.unavailable)
                return
            }
            self.apply(
                HingeSnapshot(
                    status: Self.status(from: hinge.status),
                    angle: Double(hinge.angle)
                )
            )
        }
        interaction = created
        return created
    }

    private func apply(_ next: HingeSnapshot) {
        if next != snapshot { snapshot = next }
    }

    /// Forgets what the hinge said. Only for tests.
    func reset() {
        snapshot = .unavailable
        interaction = nil
    }

    @available(iOS 27.1, *)
    private static func status(from status: UIHinge.Status) -> HingeSnapshot.Status {
        switch status {
        case .closed: return .closed
        case .partiallyOpen: return .partiallyOpen
        case .fullyOpen: return .fullyOpen
        case .unknown: return .unknown
        @unknown default: return .unknown
        }
    }
}

// MARK: - Host view

/// A zero-size view whose only job is to carry the hinge interaction into the
/// hierarchy. `UIHingeInteraction` is a `UIInteraction`, so it needs a real
/// `UIView` to live on. SwiftUI also exposes `onHingeChange` in iOS 27.1, but
/// the reader keeps this interaction as its current source of hinge updates.
struct HingeObservationView: UIViewRepresentable {

    let observer: HingeObserver

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        if let interaction = observer.makeInteraction() {
            view.addInteraction(interaction)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
