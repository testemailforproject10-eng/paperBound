//
//  EnchantedInkRevealSequence.swift
//  Paperbound
//
//  Coordinates one simultaneous, seeded ink-flow visit to a page or spread.
//

import Foundation

enum PageRevealState: Equatable {
    case waiting
    case revealing(startDate: Date, durationSeconds: Double)
    case finished
}

struct PageRevealActivation: Equatable {
    let pageIdentity: String
    let visitID: UUID
    let state: PageRevealState
}

struct EnchantedInkRevealSequence: Equatable {
    /// The ink starts flowing only once the page has finished turning and
    /// lies fully open. The sequence itself is created as the turn begins
    /// (see PageTurnVisibility.revealThreshold), so the pages prepare while
    /// they turn and the ink can start the moment the turn lands.
    static let visibilityThreshold: CGFloat = 0.999
    /// After a page turn, the page rests as blank paper this long before the
    /// ink starts, so the turn and the writing read as two separate moments.
    static let landingPause: TimeInterval = 2.5

    enum Phase: Equatable {
        case waiting
        case revealing
        case finished
    }

    let unit: Int
    let visitID: UUID
    let pageIdentities: [String]
    /// How long after the pages are open and ready the ink starts.
    let startDelay: TimeInterval

    private(set) var phase: Phase = .waiting
    private(set) var isEligible = false
    private(set) var readyPageSeeds: [String: UInt64] = [:]
    private(set) var startDates: [String: Date] = [:]
    private(set) var durations: [String: Double] = [:]
    private(set) var completedPageIdentities: Set<String> = []

    init(unit: Int, pageIdentities: [String], visitID: UUID = UUID(), startDelay: TimeInterval = 0) {
        self.unit = unit
        self.pageIdentities = pageIdentities
        self.visitID = visitID
        self.startDelay = max(0, startDelay)
    }

    /// Selecting ink on an already visible page is a new visit. Other effect
    /// changes preserve the active visit, including its preparation callbacks.
    static func applyingInkChange(
        from oldInk: InkBehavior,
        to newInk: InkBehavior,
        current: Self?,
        unit: Int,
        pageIdentities: [String],
        animationsAllowed: Bool,
        at date: Date
    ) -> Self? {
        guard oldInk != newInk else { return current }
        guard newInk == .enchanted else { return nil }
        var sequence = Self(unit: unit, pageIdentities: pageIdentities)
        if animationsAllowed {
            sequence.updateVisibility(1, at: date)
        } else {
            sequence.finish()
        }
        return sequence
    }

    mutating func updateVisibility(_ fraction: CGFloat, at date: Date) {
        guard phase == .waiting, fraction >= Self.visibilityThreshold else { return }
        isEligible = true
        startAllPagesIfReady(at: date)
    }

    @discardableResult
    mutating func pageBecameReady(
        _ pageIdentity: String,
        visitID: UUID,
        revealSeed: UInt64,
        at date: Date
    ) -> Bool {
        guard visitID == self.visitID,
              phase == .waiting,
              pageIdentities.contains(pageIdentity)
        else { return false }
        readyPageSeeds[pageIdentity] = revealSeed
        startAllPagesIfReady(at: date)
        return true
    }

    @discardableResult
    mutating func pageDidFinish(
        _ pageIdentity: String,
        visitID: UUID,
        startedAt completionStart: Date,
        at date: Date
    ) -> Bool {
        guard visitID == self.visitID,
              phase == .revealing,
              pageIdentities.contains(pageIdentity),
              startDates[pageIdentity] == completionStart,
              let duration = durations[pageIdentity],
              date.timeIntervalSince(completionStart) >= duration,
              !completedPageIdentities.contains(pageIdentity)
        else { return false }

        completedPageIdentities.insert(pageIdentity)
        if completedPageIdentities.count == pageIdentities.count {
            phase = .finished
        }
        return true
    }

    mutating func finish() {
        phase = .finished
        completedPageIdentities = Set(pageIdentities)
    }

    func activation(for pageIdentity: String) -> PageRevealActivation? {
        guard pageIdentities.contains(pageIdentity) else { return nil }
        let state: PageRevealState
        if phase == .finished || completedPageIdentities.contains(pageIdentity) {
            state = .finished
        } else if phase == .revealing,
                  let startDate = startDates[pageIdentity],
                  let duration = durations[pageIdentity] {
            state = .revealing(startDate: startDate, durationSeconds: duration)
        } else {
            state = .waiting
        }
        return PageRevealActivation(pageIdentity: pageIdentity, visitID: visitID, state: state)
    }

    private mutating func startAllPagesIfReady(at date: Date) {
        guard phase == .waiting,
              isEligible,
              !pageIdentities.isEmpty,
              pageIdentities.allSatisfy({ readyPageSeeds[$0] != nil })
        else { return }

        for pageIdentity in pageIdentities {
            guard let seed = readyPageSeeds[pageIdentity] else { continue }
            startDates[pageIdentity] = date.addingTimeInterval(startDelay)
            durations[pageIdentity] = InkBehavior.enchanted.revealDurationSeconds(seed: seed)
        }
        phase = .revealing
    }
}
