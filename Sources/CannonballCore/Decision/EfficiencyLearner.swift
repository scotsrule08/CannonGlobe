import Foundation

/// Learns this car's real consumption under FSD from recent drive segments and
/// updates `EnergyModel`'s free parameters. Docs §3.6.
public struct EfficiencyLearner: Sendable {
    public struct Segment: Sendable, Codable {
        public var distanceMi: Double
        public var meanSpeedMps: Double
        public var meanGradePercent: Double
        public var headwindMps: Double
        public var ambientC: Double
        public var fsdActive: Bool
        public var actualKWh: Double
        public var startedAt: Date

        public init(distanceMi: Double, meanSpeedMps: Double, meanGradePercent: Double,
                    headwindMps: Double, ambientC: Double, fsdActive: Bool,
                    actualKWh: Double, startedAt: Date) {
            self.distanceMi = distanceMi; self.meanSpeedMps = meanSpeedMps
            self.meanGradePercent = meanGradePercent; self.headwindMps = headwindMps
            self.ambientC = ambientC; self.fsdActive = fsdActive
            self.actualKWh = actualKWh; self.startedAt = startedAt
        }
    }

    public private(set) var model: EnergyModel
    private var segments: [Segment] = []
    /// Exponential decay half-life in miles — recent conditions dominate.
    private let halfLifeMi: Double = 60
    private let windowMi: Double = 200

    public init(model: EnergyModel = EnergyModel()) { self.model = model }

    /// Ingest a completed 5-mi segment. Manual-driving segments are kept but
    /// quarantined from the FSD fit.
    public mutating func ingest(_ s: Segment) {
        segments.append(s)
        var cum = 0.0
        segments = segments.reversed().prefix { cum += $0.distanceMi; return cum <= windowMi }.reversed()
        refit()
    }

    /// One-parameter multiplicative fit (robust with little data) applied to
    /// CdA: aero dominates highway error, and CdA absorbs roof-load/wind-model
    /// bias. Upgradeable to RLS over (CdA, Crr, hvacBias) with more segments.
    private mutating func refit() {
        let fsdSegments = segments.filter(\.fsdActive)
        guard fsdSegments.count >= 3 else { return }
        var num = 0.0, den = 0.0, weight = 1.0
        var freshModel = model
        freshModel.cdAEffective = EnergyModel().cdAEffective   // fit from prior, not drifted value
        for s in fsdSegments.reversed() {
            let predicted = freshModel.powerKW(
                speedMps: s.meanSpeedMps, gradePercent: s.meanGradePercent,
                headwindMps: s.headwindMps, tempC: s.ambientC, altitudeM: 300)
                * (s.distanceMi * 1609.34 / s.meanSpeedMps) / 3600
            guard predicted > 0.1 else { continue }
            num += weight * s.actualKWh / predicted
            den += weight
            weight *= pow(0.5, s.distanceMi / halfLifeMi)
        }
        guard den > 0 else { return }
        let scale = max(0.8, min(1.3, num / den))
        model.cdAEffective = freshModel.cdAEffective * scale
    }

    /// ±1σ fraction of the current fit residuals, consumed by buffer math.
    public var residualSigmaFraction: Double {
        let fsdSegments = segments.filter(\.fsdActive)
        guard fsdSegments.count >= 5 else { return 0.06 }   // wide prior early
        let ratios = fsdSegments.map { s -> Double in
            let predicted = model.powerKW(
                speedMps: s.meanSpeedMps, gradePercent: s.meanGradePercent,
                headwindMps: s.headwindMps, tempC: s.ambientC, altitudeM: 300)
                * (s.distanceMi * 1609.34 / s.meanSpeedMps) / 3600
            return predicted > 0.1 ? s.actualKWh / predicted : 1
        }
        let mean = ratios.reduce(0, +) / Double(ratios.count)
        let variance = ratios.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(ratios.count)
        return max(0.02, variance.squareRoot())
    }
}
