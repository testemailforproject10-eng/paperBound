import Foundation
import CoreGraphics

/// Readiness is independent from the ink GPU session. Render and visit tokens
/// prevent an old page task from starting a newer effect.
struct PageEffectVisit: Equatable {
    let unit: Int
    let visitID: UUID
    let pageRenderTokens: [String: String]
    var eligible = false
    private(set) var readyPages: Set<String> = []
    private(set) var startedAt: Date?

    mutating func setVisibleFraction(_ fraction: CGFloat, at date: Date) {
        if fraction >= 0.05 { eligible = true }
        startIfReady(at: date)
    }

    @discardableResult
    mutating func paperReady(pageIdentity: String, renderToken: String, visitID: UUID, at date: Date) -> Bool {
        guard visitID == self.visitID,
              pageRenderTokens[pageIdentity] == renderToken else { return false }
        readyPages.insert(pageIdentity)
        startIfReady(at: date)
        return true
    }

    private mutating func startIfReady(at date: Date) {
        guard startedAt == nil, eligible,
              !pageRenderTokens.isEmpty,
              readyPages.count == pageRenderTokens.count else { return }
        startedAt = date
    }
}

// Existing clients can continue to supply the same readiness tokens.
typealias FootstepVisit = PageEffectVisit
