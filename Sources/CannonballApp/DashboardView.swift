import SwiftUI
import CannonballCore

/// Drive screen: glanceable numerals only — readable from the driver's seat
/// at arm's length in 300 ms. Layout spec in docs §2.5.
public struct DashboardView: View {
    @Bindable var model: DashboardViewModel

    public init(model: DashboardViewModel) { self.model = model }

    public var body: some View {
        VStack(spacing: 24) {
            HStack {
                sourceBadge
                Spacer()
                Text(model.nextStopName).font(.title3.weight(.semibold))
            }
            HStack(alignment: .firstTextBaseline, spacing: 32) {
                BigNumber(value: model.arrivalSOCText, label: model.arrivalLabel,
                          tint: model.arrivalSOCIsHealthy ? .green : .orange)
                BigNumber(value: model.minutesToStopText, label: model.minutesLabel, tint: .primary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 32) {
                BigNumber(value: model.whPerMiText, label: "Wh/mi vs PLAN",
                          tint: model.efficiencyOnPlan ? .green : .orange)
                BigNumber(value: model.deltaVsTeslaText, label: "vs TESLA NAV", tint: .cyan)
            }
            paceRow
            actionBanner
            Spacer(minLength: 0)
        }
        .padding(24)
        .persistentSystemOverlays(.hidden)
        #if os(iOS)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        #endif
    }

    private var sourceBadge: some View {
        Text(model.sourceLabel) // "CAN" / "CLOUD" / "DR"
            .font(.caption.monospaced().bold())
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(model.sourceIsCAN ? .green.opacity(0.2) : .orange.opacity(0.25),
                        in: Capsule())
    }

    @ViewBuilder private var paceRow: some View {
        if let pace = model.paceText, let eta = model.etaText {
            HStack {
                Label("\(pace) vs plan", systemImage: "gauge.with.needle")
                    .foregroundStyle(model.paceIsAhead ? .green : .orange)
                Spacer()
                Label("ETA \(eta)", systemImage: "flag.checkered")
            }
            .font(.headline.monospacedDigit())
        }
    }

    @ViewBuilder private var actionBanner: some View {
        if let rec = model.activeRecommendation {
            Label(rec.message, systemImage: rec.isCritical ? "exclamationmark.octagon.fill" : "bolt.fill")
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(rec.isCritical ? .red.opacity(0.25) : .blue.opacity(0.2),
                            in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

struct BigNumber: View {
    var value: String
    var label: String
    var tint: Color
    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 76, weight: .black, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .contentTransition(.numericText())
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Fed from RecommendationEngine + DataFusionEngine streams; all formatting
/// happens here so the view stays dumb and cheap to re-render at 1 Hz.
@Observable public final class DashboardViewModel {
    public var nextStopName = "—"
    public var arrivalSOCText = "—"
    public var arrivalSOCIsHealthy = true
    public var minutesToStopText = "—"
    public var arrivalLabel = "ARRIVE SOC"
    public var minutesLabel = "MIN TO STOP"
    public var tripDestinationName: String?
    public var paceText: String?
    public var paceIsAhead = true
    public var etaText: String?
    public var whPerMiText = "—"
    public var efficiencyOnPlan = true
    public var deltaVsTeslaText = "—"
    public var sourceLabel = "CAN"
    public var sourceIsCAN = true
    public var activeRecommendation: Recommendation?

    public init() {}

    /// Bind the core streams; call once from the app scene.
    public func bind(states: AsyncStream<VehicleState>,
                     recommendations: AsyncStream<Recommendation>) {
        Task { @MainActor in
            for await s in states {
                sourceIsCAN = s.socPercent.source == .can
                sourceLabel = switch s.socPercent.source {
                case .can: "CAN"
                case .deadReckoned: "DR"
                default: "CLOUD"
                }
            }
        }
        Task { @MainActor in
            for await r in recommendations { activeRecommendation = r }
        }
    }
}
