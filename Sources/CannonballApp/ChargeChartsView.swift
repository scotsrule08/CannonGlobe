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

// MARK: - shared curve math

struct CurvePoint: Identifiable {
    var id: Int; var soc: Double; var kW: Double
}

enum CurveMath {
    static func referencePoints(pack: PackProfile) -> [CurvePoint] {
        let curve = ChargeCurveModel(profile: pack)
        return (0...100).map {
            CurvePoint(id: $0, soc: Double($0),
                       kW: curve.vehicleExpectedKW(soc: Double($0),
                                                   cellTempMinC: 42, cellTempMaxC: 45))
        }
    }

    static func bands(points: [CurvePoint])
        -> (idealLo: Double, idealHi: Double, taperStart: Double, peak: Double) {
        let peak = points.map(\.kW).max() ?? 250
        let ideal = points.filter { $0.kW >= peak * 0.8 }.map(\.soc)
        let idealLo = ideal.first ?? 3, idealHi = ideal.last ?? 20
        let taper = points.first { $0.soc > idealHi && $0.kW < peak * 0.4 }?.soc ?? 60
        return (idealLo, idealHi, taper, peak)
    }
}

// MARK: - the charge-curve chart (compact + fullscreen)

struct ChargeCurveChart: View {
    let points: [CurvePoint]
    let session: [AppModel.SessionSample]
    let currentSOC: Double?
    var interactive = false
    @State private var selectedSOC: Double?

    var body: some View {
        let bands = CurveMath.bands(points: points)
        let chart = Chart {
            RectangleMark(xStart: .value("SOC", bands.idealLo),
                          xEnd: .value("SOC", bands.idealHi))
                .foregroundStyle(.green.opacity(0.13))
            RectangleMark(xStart: .value("SOC", bands.taperStart), xEnd: .value("SOC", 100))
                .foregroundStyle(.red.opacity(0.07))
            ForEach(points) { p in
                LineMark(x: .value("SOC %", p.soc), y: .value("kW", p.kW),
                         series: .value("Curve", "reference"))
                    .foregroundStyle(.green)
                    .interpolationMethod(.monotone)
            }
            ForEach(session) { s in
                LineMark(x: .value("SOC %", s.soc), y: .value("kW", s.kW),
                         series: .value("Curve", "session"))
                    .foregroundStyle(.orange)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                    .interpolationMethod(.monotone)
            }
            if let last = session.last {
                PointMark(x: .value("SOC %", last.soc), y: .value("kW", last.kW))
                    .foregroundStyle(.orange)
                    .symbolSize(70)
            }
            if session.isEmpty, let soc = currentSOC {
                RuleMark(x: .value("Now", soc))
                    .foregroundStyle(.orange)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("now").font(.caption2).foregroundStyle(.orange)
                    }
            }
            if interactive, let selected = selectedSOC {
                let index = max(0, min(100, Int(selected.rounded())))
                RuleMark(x: .value("SOC %", Double(index)))
                    .foregroundStyle(.white.opacity(0.5))
                    .annotation(position: .top, spacing: 4,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        readout(atSOC: index)
                    }
            }
        }
        .chartXScale(domain: 0...100)
        .chartYAxisLabel("kW")
        .chartXAxisLabel("State of charge %")

        if interactive {
            chart
                .chartXSelection(value: $selectedSOC)
                .chartXAxis { AxisMarks(values: .stride(by: 5)) }
                .chartYAxis { AxisMarks(values: .stride(by: 25)) }
        } else {
            chart
        }
    }

    private func readout(atSOC index: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(index)% SOC").font(.caption.weight(.bold))
            Text("\(Int(points[index].kW)) kW reference")
                .font(.caption2).foregroundStyle(.green)
            if let live = nearestSessionSample(toSOC: Double(index)) {
                Text("\(Int(live.kW)) kW live at \(Int(live.soc))%")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func nearestSessionSample(toSOC soc: Double) -> AppModel.SessionSample? {
        guard let nearest = session.min(by: { abs($0.soc - soc) < abs($1.soc - soc) }),
              abs(nearest.soc - soc) <= 2 else { return nil }
        return nearest
    }
}

/// Fullscreen, self-refreshing, scrubbable — rotate to landscape for the
/// most granular view.
struct FullChargeCurveView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: AppModel.CarSnapshot?
    @State private var session: [AppModel.SessionSample] = []

    var body: some View {
        NavigationStack {
            ChargeCurveChart(
                points: CurveMath.referencePoints(pack: snapshot?.pack ?? .us2025PremiumRWD),
                session: session,
                currentSOC: snapshot?.cloud?.socPercent,
                interactive: true)
                .padding(20)
                .navigationTitle("Charge Curve")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { Button("Done") { dismiss() } }
                .task {
                    while !Task.isCancelled {
                        snapshot = await model.carSnapshot()
                        session = model.liveSessionSamples
                        try? await Task.sleep(for: .seconds(2))
                    }
                }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - insights stack

struct ChargeInsightsView: View {
    let model: AppModel
    @State private var snapshot: AppModel.CarSnapshot?
    @State private var plan: AppModel.PlanProfile?
    @State private var session: [AppModel.SessionSample] = []
    @State private var showFullCurve = false

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
                session = model.liveSessionSamples
                try? await Task.sleep(for: .seconds(5))
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showFullCurve) { FullChargeCurveView(model: model) }
        #else
        .sheet(isPresented: $showFullCurve) { FullChargeCurveView(model: model) }
        #endif
    }

    // MARK: charge curve + ideal plug-in band

    private var chargeCurveSection: some View {
        let points = CurveMath.referencePoints(pack: pack)
        let bands = CurveMath.bands(points: points)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                header("CHARGE CURVE",
                       session.isEmpty ? "Warm pack on an unshared V3+ stall"
                                       : "Live session (orange) vs the reference curve")
                Spacer()
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ChargeCurveChart(points: points, session: session, currentSOC: currentSOC)
                .frame(height: 240)
                .contentShape(Rectangle())
                .onTapGesture { showFullCurve = true }
            caption(sessionCaption(points: points)
                ?? "Ideal plug-in band: \(Int(bands.idealLo))–\(Int(bands.idealHi))% (≥\(Int(bands.peak * 0.8)) kW). Past \(Int(bands.taperStart))% the taper makes minutes at the stall cost more than they buy. Tap for fullscreen; rotate for detail.")
        }
    }

    /// "212 kW at 18%: 93% of the reference" while a session trace exists.
    private func sessionCaption(points: [CurvePoint]) -> String? {
        guard let last = session.last else { return nil }
        let index = max(0, min(points.count - 1, Int(last.soc.rounded())))
        let reference = points[index].kW
        guard reference > 1 else { return nil }
        let ratio = Int((last.kW / reference * 100).rounded())
        let health = ratio >= 90 ? "on pace" : (ratio >= 70 ? "below the curve" : "well below the curve, check the watchdog")
        return "Live: \(Int(last.kW)) kW at \(Int(last.soc))%, \(ratio)% of the reference (\(health)). Tap for fullscreen."
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
