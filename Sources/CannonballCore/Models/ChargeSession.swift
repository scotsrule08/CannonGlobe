import Foundation

public enum ChargeLimitReason: String, Codable, Sendable {
    case none            // vehicle curve is the binding limit (healthy)
    case thermalHot
    case thermalCold
    case sharedPower     // V2 paired neighbor (or site power budget)
    case badStall        // underperformance not explained by the above
    case siteCap
    case rampUp          // first ~60 s handshake/ramp
}

public struct ChargeSample: Codable, Sendable {
    public var t: Date
    public var socPercent: Double
    public var expectedKW: Double
    public var actualKW: Double
    public var cellTempMaxC: Double
    public var bmsLimitKW: Double
    public var limitReason: ChargeLimitReason

    public init(t: Date, socPercent: Double, expectedKW: Double, actualKW: Double,
                cellTempMaxC: Double, bmsLimitKW: Double, limitReason: ChargeLimitReason) {
        self.t = t; self.socPercent = socPercent; self.expectedKW = expectedKW
        self.actualKW = actualKW; self.cellTempMaxC = cellTempMaxC
        self.bmsLimitKW = bmsLimitKW; self.limitReason = limitReason
    }
}

public enum WatchdogState: String, Codable, Sendable {
    case rampUp, healthy, degraded, severe
}

public struct WatchdogEvent: Codable, Sendable {
    public var t: Date
    public var state: WatchdogState
    public var reason: ChargeLimitReason
    public var ratio: Double                     // actual / expected
    public var recommendation: String?

    public init(t: Date, state: WatchdogState, reason: ChargeLimitReason,
                ratio: Double, recommendation: String? = nil) {
        self.t = t; self.state = state; self.reason = reason
        self.ratio = ratio; self.recommendation = recommendation
    }
}

public struct ChargeSession: Codable, Sendable, Identifiable {
    public var id: UUID
    public var siteID: String
    public var stallLabel: String?
    public var startedAt: Date
    public var endedAt: Date?
    public var socStart: Double
    public var socEnd: Double?
    public var targetSOC: Double
    public var samples: [ChargeSample]
    public var events: [WatchdogEvent]

    public init(id: UUID = UUID(), siteID: String, stallLabel: String? = nil,
                startedAt: Date, socStart: Double, targetSOC: Double) {
        self.id = id; self.siteID = siteID; self.stallLabel = stallLabel
        self.startedAt = startedAt; self.socStart = socStart; self.targetSOC = targetSOC
        self.samples = []; self.events = []
    }

    public var energyAddedKWh: Double {
        guard samples.count > 1 else { return 0 }
        return zip(samples, samples.dropFirst()).reduce(0) { acc, pair in
            acc + pair.0.actualKW * pair.1.t.timeIntervalSince(pair.0.t) / 3600
        }
    }
    public var meanPowerKW: Double {
        guard let last = samples.last, let first = samples.first,
              last.t > first.t else { return 0 }
        return energyAddedKWh / (last.t.timeIntervalSince(first.t) / 3600)
    }
    /// Time-weighted actual/expected over non-rampUp samples; < 0.9 is a bad session.
    public var performanceRatio: Double {
        let usable = samples.filter { $0.limitReason != .rampUp && $0.expectedKW > 1 }
        guard !usable.isEmpty else { return 1 }
        return usable.reduce(0) { $0 + $1.actualKW / $1.expectedKW } / Double(usable.count)
    }
}
