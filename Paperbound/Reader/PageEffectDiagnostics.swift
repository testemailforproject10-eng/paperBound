import Foundation

/// Small debug-only probe for full-reader regression tests and Instruments.
/// This observes real Canvas submissions rather than synthesizing activation.
final class PageEffectDiagnostics: @unchecked Sendable {
    static let shared = PageEffectDiagnostics()
    struct Snapshot { var effect: PageEffect; var frames: Int; var sprites: Int; var maximumDrawMS: Double }
    private let lock = NSLock()
    private var papers: [String: TimeInterval] = [:]
    private var visits: [UUID: Snapshot] = [:]
    func record(visit: UUID, effect: PageEffect, sprites: Int, milliseconds: Double) {
        #if DEBUG
        lock.lock(); defer { lock.unlock() }
        var value = visits[visit] ?? Snapshot(effect:effect,frames:0,sprites:0,maximumDrawMS:0)
        value.frames += 1; value.sprites = sprites
        value.maximumDrawMS = max(value.maximumDrawMS,milliseconds)
        visits[visit] = value
        #endif
    }
    func paperReady(_ identity: String) {
        #if DEBUG
        lock.lock(); defer { lock.unlock() }
        if papers.count > 256 { papers.removeAll() }
        papers[identity] = ProcessInfo.processInfo.systemUptime
        #endif
    }
    func clearPaperReadiness() { lock.lock(); papers.removeAll(); lock.unlock() }
    var paperTimes: [String:TimeInterval] { lock.lock(); defer { lock.unlock() }; return papers }
    func remove(_ visit: UUID) { lock.lock(); visits.removeValue(forKey: visit); lock.unlock() }
    var snapshots: [UUID:Snapshot] { lock.lock(); defer { lock.unlock() }; return visits }
}
