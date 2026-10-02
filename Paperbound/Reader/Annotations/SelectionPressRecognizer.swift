//
//  SelectionPressRecognizer.swift
//  Paperbound
//
//  The long press that starts a text selection, as a UIKit recognizer.
//
//  A SwiftUI long press sequenced before a drag, attached to a page inside
//  the paging scroll view, holds every touch on the page: swipes no longer
//  turn it and taps no longer land. UILongPressGestureRecognizer fails as
//  soon as the finger travels, so a swipe still belongs to the scroll view
//  and a quick tap still belongs to the page; once it does recognize, it
//  keeps reporting the finger, which is the drag that extends by words.
//

import SwiftUI
import UIKit

struct SelectionPressRecognizer: UIGestureRecognizerRepresentable {
    var isEnabled: Bool
    /// The press landed and was held: points are in the attached view's space.
    var onBegan: (CGPoint) -> Void
    var onMoved: (_ start: CGPoint, _ location: CGPoint) -> Void
    var onEnded: () -> Void

    final class Coordinator {
        var start: CGPoint?
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = 0.4
        recognizer.allowableMovement = 12
        recognizer.isEnabled = isEnabled
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        if recognizer.isEnabled != isEnabled { recognizer.isEnabled = isEnabled }
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        let location = context.converter.localLocation
        switch recognizer.state {
        case .began:
            context.coordinator.start = location
            onBegan(location)
        case .changed:
            guard let start = context.coordinator.start else { return }
            onMoved(start, location)
        case .ended, .cancelled, .failed:
            guard context.coordinator.start != nil else { return }
            context.coordinator.start = nil
            onEnded()
        default:
            break
        }
    }
}
