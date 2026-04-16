import Foundation

enum SmartDeliveryConfidence: String, CaseIterable {
    case high
    case medium
    case low
    case waiting
}

actor SmartDeliveryPolicyStore {
    static let shared = SmartDeliveryPolicyStore()

    private struct RouteStats {
        var lastSuccessAt: Date?
        var lastFailureAt: Date?
        var consecutiveFailures: Int = 0
        var lastLatency: TimeInterval?
    }

    private struct SlowSendWindow {
        var timestamps: [Date] = []
        var forceOnlineUntil: Date?
        var routeStats: [OfflineTransportPath: RouteStats] = [:]
    }

    private var windowsByUserID: [UUID: SlowSendWindow] = [:]

    func shouldForceOnline(for userID: UUID, now: Date = .now) -> Bool {
        prune(for: userID, now: now)
        guard let until = windowsByUserID[userID]?.forceOnlineUntil else { return false }
        return until > now
    }

    @discardableResult
    func recordSlowFallback(for userID: UUID, now: Date = .now) -> Bool {
        prune(for: userID, now: now)
        var window = windowsByUserID[userID] ?? SlowSendWindow()
        window.timestamps.append(now)

        if window.timestamps.count >= 4 {
            window.forceOnlineUntil = now.addingTimeInterval(10 * 60)
        }

        windowsByUserID[userID] = window
        return window.forceOnlineUntil != nil
    }

    func recordOfflineSuccess(
        for userID: UUID,
        path: OfflineTransportPath,
        latency: TimeInterval? = nil,
        now: Date = .now
    ) {
        prune(for: userID, now: now)
        var window = windowsByUserID[userID] ?? SlowSendWindow()
        var stats = window.routeStats[path] ?? RouteStats()
        stats.lastSuccessAt = now
        stats.lastFailureAt = nil
        stats.consecutiveFailures = 0
        stats.lastLatency = latency
        window.routeStats[path] = stats
        window.forceOnlineUntil = nil
        windowsByUserID[userID] = window
    }

    func recordOfflineFailure(
        for userID: UUID,
        path: OfflineTransportPath?,
        now: Date = .now
    ) {
        prune(for: userID, now: now)
        guard let path else { return }
        var window = windowsByUserID[userID] ?? SlowSendWindow()
        var stats = window.routeStats[path] ?? RouteStats()
        stats.lastFailureAt = now
        stats.consecutiveFailures += 1
        window.routeStats[path] = stats
        windowsByUserID[userID] = window
    }

    func preferredOfflinePath(
        for userID: UUID,
        availablePaths: [OfflineTransportPath],
        now: Date = .now
    ) -> OfflineTransportPath? {
        prune(for: userID, now: now)
        let normalizedPaths = normalized(availablePaths: availablePaths)
        guard normalizedPaths.isEmpty == false else { return nil }

        let routeStats = windowsByUserID[userID]?.routeStats ?? [:]
        return normalizedPaths.max { lhs, rhs in
            score(for: lhs, stats: routeStats[lhs], now: now) < score(for: rhs, stats: routeStats[rhs], now: now)
        }
    }

    func shouldPreferOnline(
        for userID: UUID,
        availablePaths: [OfflineTransportPath],
        networkAllowed: Bool,
        now: Date = .now
    ) -> Bool {
        prune(for: userID, now: now)
        guard networkAllowed else { return false }

        let normalizedPaths = normalized(availablePaths: availablePaths)
        guard normalizedPaths.isEmpty == false else { return true }

        let routeStats = windowsByUserID[userID]?.routeStats ?? [:]
        let directPaths = normalizedPaths.filter { $0 != .meshRelay }
        let relayOnly = directPaths.isEmpty

        if relayOnly {
            let relayStats = routeStats[.meshRelay]
            if hasFreshSuccess(relayStats, within: 3 * 60, now: now) {
                return false
            }
            if hasFreshFailure(relayStats, within: 2 * 60, now: now) {
                return true
            }
            return shouldForceOnline(for: userID, now: now) || relayStats?.lastSuccessAt == nil
        }

        if shouldForceOnline(for: userID, now: now),
           directPaths.contains(where: { hasFreshSuccess(routeStats[$0], within: 90, now: now) }) == false {
            return true
        }

        return directPaths.allSatisfy {
            isCoolingDown(routeStats[$0], now: now)
        }
    }

    func deliveryConfidence(
        for userID: UUID,
        availablePaths: [OfflineTransportPath],
        networkAllowed: Bool,
        now: Date = .now
    ) -> SmartDeliveryConfidence {
        prune(for: userID, now: now)

        let normalizedPaths = normalized(availablePaths: availablePaths)
        guard normalizedPaths.isEmpty == false else {
            return networkAllowed ? .low : .waiting
        }

        let routeStats = windowsByUserID[userID]?.routeStats ?? [:]
        let preferredPath = preferredOfflinePath(for: userID, availablePaths: normalizedPaths, now: now)
        let preferredStats = preferredPath.flatMap { routeStats[$0] }
        let directPaths = normalizedPaths.filter { $0 != .meshRelay }
        let relayOnly = directPaths.isEmpty

        if relayOnly {
            if hasFreshSuccess(preferredStats, within: 3 * 60, now: now) {
                return .medium
            }
            return hasFreshFailure(preferredStats, within: 2 * 60, now: now) ? .low : .medium
        }

        if shouldForceOnline(for: userID, now: now),
           shouldPreferOnline(for: userID, availablePaths: normalizedPaths, networkAllowed: networkAllowed, now: now) {
            return .low
        }

        if hasFreshSuccess(preferredStats, within: 2 * 60, now: now) {
            return .high
        }

        if hasFreshSuccess(preferredStats, within: 5 * 60, now: now) {
            return .medium
        }

        if directPaths.contains(where: { isCoolingDown(routeStats[$0], now: now) }) {
            return .low
        }

        return .medium
    }

    private func prune(for userID: UUID, now: Date) {
        guard var window = windowsByUserID[userID] else { return }
        let cutoff = now.addingTimeInterval(-(10 * 60))
        window.timestamps.removeAll(where: { $0 < cutoff })
        if let until = window.forceOnlineUntil, until <= now {
            window.forceOnlineUntil = nil
        }
        windowsByUserID[userID] = window
    }

    private func normalized(availablePaths: [OfflineTransportPath]) -> [OfflineTransportPath] {
        Array(Set(availablePaths)).sorted { lhs, rhs in
            lhs.priority < rhs.priority
        }
    }

    private func score(
        for path: OfflineTransportPath,
        stats: RouteStats?,
        now: Date
    ) -> Int {
        var value: Int
        switch path {
        case .localNetwork:
            value = 300
        case .bluetooth:
            value = 220
        case .meshRelay:
            value = 120
        }

        if hasFreshSuccess(stats, within: 2 * 60, now: now) {
            value += 140
        } else if hasFreshSuccess(stats, within: 5 * 60, now: now) {
            value += 70
        }

        if let latency = stats?.lastLatency {
            if latency <= 1.5 {
                value += 40
            } else if latency <= 3 {
                value += 20
            } else if latency > 4 {
                value -= 25
            }
        }

        if let failures = stats?.consecutiveFailures, failures > 0 {
            value -= failures * 70
        }

        if hasFreshFailure(stats, within: 90, now: now) {
            value -= 140
        }

        return value
    }

    private func isCoolingDown(_ stats: RouteStats?, now: Date) -> Bool {
        if hasFreshSuccess(stats, within: 90, now: now) {
            return false
        }

        if let failures = stats?.consecutiveFailures, failures >= 2 {
            return true
        }

        return hasFreshFailure(stats, within: 90, now: now)
    }

    private func hasFreshSuccess(_ stats: RouteStats?, within interval: TimeInterval, now: Date) -> Bool {
        guard let lastSuccessAt = stats?.lastSuccessAt else { return false }
        return lastSuccessAt >= now.addingTimeInterval(-interval)
    }

    private func hasFreshFailure(_ stats: RouteStats?, within interval: TimeInterval, now: Date) -> Bool {
        guard let lastFailureAt = stats?.lastFailureAt else { return false }
        return lastFailureAt >= now.addingTimeInterval(-interval)
    }
}
