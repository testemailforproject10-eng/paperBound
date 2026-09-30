import Foundation
import os

enum InkMetrics {
    static let log = OSLog(subsystem: "com.paperbound.reader", category: "Ink")
    static func begin(_ name: StaticString) -> (OSSignpostID, TimeInterval) {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        trace("BEGIN \(name)")
        return (id, ProcessInfo.processInfo.systemUptime)
    }
    @discardableResult
    static func end(_ name: StaticString, _ token: (OSSignpostID, TimeInterval)) -> Double {
        let ms = (ProcessInfo.processInfo.systemUptime - token.1) * 1000
        os_signpost(.end, log: log, name: name, signpostID: token.0, "%.3f ms", ms)
        trace("END \(name) \(String(format: "%.1f", ms)) ms")
        return ms
    }
    static func event(_ name: StaticString) {
        os_signpost(.event, log: log, name: name)
        trace("EVENT \(name)")
    }

    /// Opt-in diagnostics for complete launches, rather than warmed unit tests.
    static func trace(_ message: @autoclosure () -> String) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-paperbound-startup-trace")
                || ProcessInfo.processInfo.environment["PAPERBOUND_INK_TRACE"] == "1" else { return }
        NSLog("PB_TIMING %.3f %@ main=%d", ProcessInfo.processInfo.systemUptime, message(), Thread.isMainThread)
        #endif
    }
}
