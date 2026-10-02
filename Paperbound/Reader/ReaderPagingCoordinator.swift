import Foundation
import Observation

struct ReaderNavigationRequest: Equatable {
    enum Source: String { case opening, edgeTap, slider, destination, swipe, settings }
    let id = UUID()
    let pageIndex: Int
    let source: Source
}

struct InkPreparationIdentity: Equatable, Hashable {
    let page: String
    let render: String
    let visit: UUID
}

/// Owns visits, independently of the ordering of SwiftUI scroll callbacks.
@MainActor @Observable
final class ReaderPagingCoordinator {
    private(set) var requestedUnit: Int?
    private(set) var observedUnit: Int?
    private(set) var settledUnit: Int?
    private(set) var source: ReaderNavigationRequest.Source = .opening
    private(set) var sequence: EnchantedInkRevealSequence?
    private(set) var renderIdentities: [String: String] = [:]
    private(set) var pendingReplay = false
    private(set) var visitCount = 0
    private(set) var completedVisits = 0
    private(set) var firstFrames: Set<InkPreparationIdentity> = []
    private(set) var firstFrameCount = 0
    private(set) var lastFinishReason: String?
    var incomingUnit: Int? { sequence?.unit != settledUnit ? sequence?.unit : nil }
    var isProgrammatic: Bool { requestedUnit != nil && source != .swipe }

    func request(unit: Int, pages: [String], renders: [String: String],
                 source: ReaderNavigationRequest.Source, enchanted: Bool,
                 animationsAllowed: Bool, force: Bool = false) {
        if !force, sequence?.unit == unit, requestedUnit == unit { return }
        if !force, settledUnit == unit, requestedUnit == nil { return }
        self.source = source
        requestedUnit = unit
        renderIdentities = renders
        firstFrames.removeAll()
        // A turned page rests blank before the ink starts; opening the book
        // or switching the ink on writes straight away.
        let delay = source == .opening || source == .settings ? 0 : EnchantedInkRevealSequence.landingPause
        sequence = enchanted
            ? EnchantedInkRevealSequence(unit: unit, pageIdentities: pages, startDelay: delay)
            : nil
        if enchanted { visitCount += 1 }
        if !animationsAllowed { finish(reason: "accessibility or lifecycle") }
        trace("request unit=\(unit)")
    }

    func observe(unit: Int, fraction: CGFloat, at date: Date) {
        observedUnit = unit
        guard sequence?.unit == unit else { return }
        let before = sequence?.phase
        sequence?.updateVisibility(fraction, at: date)
        if before != sequence?.phase { trace("activate") }
    }

    /// Returns false for intermediate boundaries crossed by a distant jump.
    @discardableResult func settle(unit: Int, at date: Date) -> Bool {
        if isProgrammatic, requestedUnit != unit { return false }
        if let previous = settledUnit, unit == previous, sequence?.unit != unit {
            sequence = nil
            renderIdentities = [:]
            trace("cancel returned to origin")
        }
        observe(unit: unit, fraction: 1, at: date)
        settledUnit = unit
        requestedUnit = nil
        return true
    }

    func readiness(_ identity: InkPreparationIdentity, seed: UInt64, at date: Date) {
        guard matches(identity) else { trace("reject stale readiness"); return }
        let before = sequence?.phase
        sequence?.pageBecameReady(identity.page, visitID: identity.visit, revealSeed: seed, at: date)
        if before != sequence?.phase { trace("activate") }
    }

    func firstFrame(_ identity: InkPreparationIdentity) {
        guard matches(identity), sequence?.phase == .revealing else { return }
        if firstFrames.insert(identity).inserted { firstFrameCount += 1 }
        trace("first simulated frame page=\(identity.page) render=\(identity.render)")
    }

    func completed(_ identity: InkPreparationIdentity, startedAt: Date, at date: Date) {
        guard matches(identity) else { trace("reject stale completion"); return }
        let before = sequence?.phase
        sequence?.pageDidFinish(identity.page, visitID: identity.visit, startedAt: startedAt, at: date)
        if before != .finished, sequence?.phase == .finished {
            completedVisits += 1
            lastFinishReason = "simulation complete"
            trace("complete")
        }
    }

    func deferReplay() {
        finish(reason: "await settings dismissal")
        pendingReplay = true
    }
    func consumeReplay() { pendingReplay = false }
    func disable() {
        finish(reason: "ink disabled")
        sequence = nil
        pendingReplay = false
    }
    func finish(reason: String) {
        sequence?.finish()
        lastFinishReason = reason
        trace("finish reason=\(reason)")
    }
    func relocate(unit: Int) {
        settledUnit = unit
        observedUnit = unit
        requestedUnit = nil
    }
    private func matches(_ identity: InkPreparationIdentity) -> Bool {
        sequence?.visitID == identity.visit && renderIdentities[identity.page] == identity.render
    }
    private func trace(_ event: String) {
        InkMetrics.trace("Pager \(event) source=\(source.rawValue) visit=\(sequence?.visitID.uuidString ?? "none")")
    }
}
