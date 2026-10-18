//
//  HostedTestWindow.swift
//  PaperboundTests
//
//  A window for tests that put a real view controller on screen, and the
//  teardown that takes it off again.
//
//  Hiding a window is not enough. A window made with `UIWindow(windowScene:)`
//  stays in its scene after `isHidden = true`, keeping its root view
//  controller alive. For the EPUB tests that root is a Readium navigator
//  with a live WKWebView, and a web view left running stalled the full-reader
//  tests that run later in the same process: their pages stopped becoming
//  ready and their ink reveals never finished. `close()` detaches the window
//  from the scene, drops the controller and lets WebKit wind down.
//

import UIKit
import XCTest

@MainActor
final class HostedTestWindow {
    let window: UIWindow

    /// Puts `controller` on screen in the host app's scene, above everything
    /// else, at `size`.
    init(_ controller: UIViewController, size: CGSize) throws {
        // Attached to the host app's scene: a scene-less window may never be
        // laid out, leaving a web view 0×0.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.windowLevel = .alert + 1
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
    }

    /// Takes the window and everything in it off screen for good. Safe to
    /// call more than once.
    func close() async {
        guard window.windowScene != nil || window.rootViewController != nil else { return }
        window.isHidden = true
        window.rootViewController?.view.removeFromSuperview()
        window.rootViewController = nil
        window.windowScene = nil
        // WebKit tears its views down asynchronously; give it a beat before
        // the next test starts drawing.
        try? await Task.sleep(for: .milliseconds(300))
    }
}
