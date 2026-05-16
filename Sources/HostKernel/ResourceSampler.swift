import Foundation

/// Tracks per-plugin runtime metrics: fetch count, latency distribution,
/// error rate, last-fetch timestamp. The Plugin Manager UI reads from
/// `snapshot()` to render health pills + drill-in details.
public final class ResourceSampler: @unchecked Sendable {
    public struct PluginMetrics: Sendable {
        public var totalFetches: Int = 0
        public var totalErrors: Int = 0
        /// Spawn count in the last minute. Reset by `resetMinuteCounters`.
        public var spawnsLastMinute: Int = 0
        /// Last 100 fetch latencies (ms) — used for p50/p95.
        public var latencies: [Int] = []
        public var lastFetchAt: Date?
        public var lastErrorAt: Date?
        public var lastError: String?
        public var lastPayloadBytes: Int = 0

        public var p50LatencyMs: Int { percentile(0.5) }
        public var p95LatencyMs: Int { percentile(0.95) }

        private func percentile(_ p: Double) -> Int {
            guard !latencies.isEmpty else { return 0 }
            let sorted = latencies.sorted()
            let idx = min(sorted.count - 1, Int(Double(sorted.count) * p))
            return sorted[idx]
        }
    }

    private var byPlugin: [String: PluginMetrics] = [:]
    private let lock = NSLock()

    public init() {}

    /// Record one fetch outcome.
    public func recordFetch(plugin: String,
                            latencyMs: Int,
                            payloadBytes: Int,
                            error: String?) {
        lock.lock(); defer { lock.unlock() }
        var m = byPlugin[plugin] ?? PluginMetrics()
        m.totalFetches += 1
        m.spawnsLastMinute += 1
        m.latencies.append(latencyMs)
        if m.latencies.count > 100 {
            m.latencies.removeFirst(m.latencies.count - 100)
        }
        m.lastFetchAt = Date()
        m.lastPayloadBytes = payloadBytes
        if let error {
            m.totalErrors += 1
            m.lastErrorAt = Date()
            m.lastError = error
        }
        byPlugin[plugin] = m
    }

    /// Snapshot for UI rendering. Cheap copy of the dict.
    public func snapshot() -> [String: PluginMetrics] {
        lock.lock(); defer { lock.unlock() }
        return byPlugin
    }

    public func resetMinuteCounters() {
        lock.lock(); defer { lock.unlock() }
        for key in byPlugin.keys {
            byPlugin[key]?.spawnsLastMinute = 0
        }
    }
}
