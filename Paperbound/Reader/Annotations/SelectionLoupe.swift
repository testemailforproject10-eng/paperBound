//
//  SelectionLoupe.swift
//  Paperbound
//
//  The system text loupe, driven from SwiftUI. While a finger selects or drags
//  a handle, the reader sees the text under it magnified above the finger,
//  exactly as in any other iOS text view.
//
//  UITextLoupeSession magnifies whatever is drawn beneath the view it is
//  attached to, so this host is a transparent, touch-transparent UIView laid
//  over the pages. Points are in the host's own coordinates.
//

import SwiftUI
import UIKit

struct SelectionLoupe: UIViewRepresentable {
    /// Where to magnify, or nil to put the loupe away.
    let point: CGPoint?

    func makeUIView(context: Context) -> LoupeHostView {
        let view = LoupeHostView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: LoupeHostView, context: Context) {
        view.show(at: point)
    }

    static func dismantleUIView(_ view: LoupeHostView, coordinator: ()) {
        view.show(at: nil)
    }
}

final class LoupeHostView: UIView {
    private var session: UITextLoupeSession?

    func show(at point: CGPoint?) {
        guard let point else {
            session?.invalidate()
            session = nil
            return
        }
        if let session {
            session.move(to: point, withCaretRect: .null, trackingCaret: false)
        } else {
            session = UITextLoupeSession.begin(at: point, fromSelectionWidgetView: nil, in: self)
        }
    }
}
