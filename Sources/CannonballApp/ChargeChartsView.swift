import SwiftUI
import Charts
import CannonballCore

/// Charge tab = the live session panel plus the physics graphs that explain
/// every recommendation: where to plug in, what temperature to arrive at,
/// and the plan's SOC sawtooth.
struct ChargeTabView: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ChargeScreenView(model: model.charge)
                ChargeInsightsView(model: model)
            }
        }
    }
}

struct ChargeInsightsView: View {
    let model: AppModel
    @State private var snapshot: AppModel.CarSnapshot?
    @State private var plan: AppModel.PlanProfile?

    private var pack: PackProfile { snapshot?.pack ?? .us2025PremiumRWD }
    private var currentSOC: Double? { snapshot?.cloud?.socPercent }
    private var cellTempMax: Double? { snapshot?.cloud?.moduleTempMaxC }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            chargeCurveSection
            tempFactorSection
            if let plan, plan.points.count >= 2 {
                planProfileSection(plan)
            }
        }
        .padding(24)
        .task {
            while !Task.isCancelled {
                snapshot = await model.carSnapshot()
                plan = model.planProfile()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    // MARK: charge curve + ideal plug-in band

    private struct CurvePoint: Identifiable {
        var id: Int; var soc: Double; var kW: Double
    }

    private var curvePoints: [CurvePoint] {
        let curve = ChargeCurveModel(profile: pack)
        return (0...100).map {
            CurvePoint(id: $0, soc: Double($0),
                       kW: curve.vehicleExpectedKW(soc: Double($0),
                                                   cellTempMinC: 42, cellTempMaxC: 45))
        }
    }

    private var chargeCurveSection: some View {
        let points = curvePoints
        let peak = points.map(\.kW).max() ?? pack.peakDCkW
        let ideal = points.filter { $0.kW >= peak * 0.8 }.map(\.soc)
        let idealLo = ideal.first ?? 3, idealHi = ideal.last ?? 20
        let taperStart = points.first { $0.soc > idealHi && $0.kW < peak * 0.4 }?.soc ?? 60

        return VStack(alignment: .leading, spacing: 8) {
            header("CHARGE CURVE", "Warm pack on an unshared V3+ stall")
            Chart {
                RectangleMark(xStart: .value("SOC", idealLo), xEnd: .value("SOC", idealHi))
                    .foregroundStyle(.green.opacity(0.13))
                RectangleMark(xStart: .value("SOC", taperStart), xEnd: .value("SOC", 100))
                    .foregroundStyle(.red.opacity(0.07))
                ForEach(points) { p in
                    LineMark(x: .value("SOC %", p.soc), y: .value("kW", p.kW))
                        .foregroundStyle(.green)
                        .interpolationMethod(.monotone)
                }
                if let soc = currentSOC {
                    RuleMark(x: .value("Now", soc))
                        .foregroundStyle(.orange)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("now").font(.caption2).foregroundStyle(.orange)
                        }
                }
            }
            .chartYAxisLabel("kW")
            .chartXAxisLabel("State of charge %")
            .frame(height: 190)
            caption("Ideal plug-in band: \(Int(idealLo))–\(Int(idealHi))% (≥\(Int(peak * 0.8)) kW). Past \(Int(taperStart))% the taper makes minutes at the stall cost more than they buy.")
        }
    }

    // MARK: temperature acceptance + ideal precondition window

    private var tempFactorSection: some View {
        let curve = ChargeCurveModel(profile: pack)
        let reference = curve.vehicleExpectedKW(soc: 12, cellTempMinC: 30, cellTempMaxC: 35)
        let points = stride(from: -10.0, through: 60, by: 1).map { t in
            CurvePoint(id: Int(t + 10), soc: t,
                       kW: curve.vehicleExpectedKW(soc: 12, cellTempMinC: t, cellTempMaxC: t)
                           / max(1, reference) * 100)
        }
        let band = pack.idealSuperchargeCellTempC

        return VStack(alignment: .leading, spacing: 8) {
            header("CELL TEMP vs CHARGE POWER", "Why preconditioning matters")
            Chart {
                RectangleMark(xStart: .value("°C", band.lowerBound),
                              xEnd: .value("°C", band.upperBound))
                    .foregroundStyle(.green.opacity(0.13))
                ForEach(points) { p in
                    LineMark(x: .value("Cell °C", p.soc), y: .value("% of peak", p.kW))
                        .foregroundStyle(.cyan)
                        .interpolationMethod(.monotone)
                }
                if let temp = cellTempMax {
                    RuleMark(x: .value("Now", temp))
                        .foregroundStyle(.orange)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("now").font(.caption2).foregroundStyle(.orange)
                        }
                }
            }
            .chartYAxisLabel("% of peak power")
            .chartXAxisLabel("Max cell temperature °C")
            .frame(height: 170)
            caption("Arrive in the \(Int(band.lowerBound))–\(Int(band.upperBound)) °C window for full power. A 5 °C pack accepts roughly a third of peak; above 50 °C the hot-side limit bites.")
        }
    }

    // MARK: plan SOC sawtooth

    private func planProfileSection(_ plan: AppModel.PlanProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header("PLAN PROFILE", "SOC over the remaining route")
            Chart {
                RuleMark(y: .value("Floor", pack.bufferFloorSOC))
                    .foregroundStyle(.red.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                ForEach(plan.points) { p in
                    LineMark(x: .value("Miles from here", p.mile), y: .value("SOC %", p.soc))
                        .foregroundStyle(.green)
                }
                ForEach(plan.stops) { s in
                    PointMark(x: .value("Miles from here", s.mile), y: .value("SOC %", s.soc))
                        .foregroundStyle(.orange)
                }
            }
            .chartYScale(domain: 0...100)
            .chartYAxisLabel("SOC %")
            .chartXAxisLabel("Miles from here")
            .frame(height: 190)
            caption(plan.stops.isEmpty
                ? "Direct to destination, no stops needed."
                : "Stops: " + plan.stops.map(\.name).joined(separator: " → ")
                    + ". Dots are arrival SOCs; the dashed line is the \(Int(pack.bufferFloorSOC))% buffer floor.")
        }
    }

    // MARK: bits

    private func header(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.bold))
            Text(subtitle).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}
