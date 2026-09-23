//
//  NativePDFReaderView.swift
//  Paperbound
//
//  Pristine mode. PDFKit's own view, with nothing masked, nothing rasterized
//  and nothing removed: real text selection, real search highlighting, real
//  zoom, real accessibility.
//
//  This view is the reason the compositor is allowed to rasterize at all. The
//  document layer is always one tap away and always complete.
//

import PDFKit
import SwiftUI

struct NativePDFReaderView: UIViewRepresentable {

    let document: PDFDocument
    let pageIndex: Int
    let twoUp: Bool
    let backgroundColor: UIColor
    var highlightedSelections: [PDFSelection] = []
    var onPageChange: (Int) -> Void

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = true
        view.backgroundColor = backgroundColor
        view.displayDirection = .horizontal
        view.displayMode = twoUp ? .twoUpContinuous : .singlePage
        view.usePageViewController(!twoUp, withViewOptions: nil)
        view.minScaleFactor = view.scaleFactorForSizeToFit * 0.5
        view.maxScaleFactor = 8

        context.coordinator.attach(to: view, onPageChange: onPageChange)
        goTo(pageIndex, in: view)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document {
            view.document = document
        }
        view.backgroundColor = backgroundColor

        let desiredMode: PDFDisplayMode = twoUp ? .twoUpContinuous : .singlePage
        if view.displayMode != desiredMode {
            view.displayMode = desiredMode
            view.usePageViewController(!twoUp, withViewOptions: nil)
            // Changing the mode resets the visible page; put the reader back.
            goTo(pageIndex, in: view)
        }

        if let current = view.currentPage,
           document.index(for: current) != pageIndex {
            goTo(pageIndex, in: view)
        }

        if view.highlightedSelections?.count != highlightedSelections.count {
            view.highlightedSelections = highlightedSelections.isEmpty ? nil : highlightedSelections
        }
    }

    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.detach()
    }

    private func goTo(_ index: Int, in view: PDFView) {
        guard index >= 0, index < document.pageCount, let page = document.page(at: index) else { return }
        view.go(to: page)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        private var observer: NSObjectProtocol?
        private weak var view: PDFView?
        private var onPageChange: ((Int) -> Void)?

        func attach(to view: PDFView, onPageChange: @escaping (Int) -> Void) {
            self.view = view
            self.onPageChange = onPageChange
            observer = NotificationCenter.default.addObserver(
                forName: .PDFViewPageChanged,
                object: view,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self,
                          let view = self.view,
                          let document = view.document,
                          let page = view.currentPage
                    else { return }
                    self.onPageChange?(document.index(for: page))
                }
            }
        }

        func detach() {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
            observer = nil
            view = nil
            onPageChange = nil
        }

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}
