import SwiftUI
import CannonballCore

/// Charge screen — auto-presented on plug-in (docs §2.5). The one number that
/// matters is DEPART AT; everything else is watchdog context.
public struct ChargeScreenView: View {
    @Bindable var model: ChargeViewModel

    public init(model: ChargeViewModel) { self.model = model }

    public var body: some View {
        VStack(spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading) {
                    Text("DEPART AT").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(model.targetSOCText)
                        .font(.system(size: 96, weight: .black, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.green)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text(model.timeRemainingText)
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("TO TARGET").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }

            powerRow

            HStack(spacing: 24) {
                metric("SOC", model.socText)
                metric("CELL MAX", model.cellTempText)
                metric("SESSION", model.energyAddedText)
            }

            watchdogBanner
            Spacer(minLength: 0)
        }
        .padding(24)
    }

    private var powerRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(model.actualKWText)
                    .font(.system(size: 64, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(model.ratioIsHealthy ? AnyShapeStyle(.primary) : AnyShapeStyle(.orange))
                Text("/ \(model.expectedKWText) kW expected")
                    .font(.title3).foregroundStyle(.secondary)
            }
            ProgressView(value: min(1, model.ratio))
                .tint(model.ratioIsHealthy ? .green : (model.ratio > 0.7 ? .orange : .red))
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.weight(.bold)).monospacedDigit()
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var watchdogBanner: some View {
        if let verdict = model.watchdogText {
            Label(verdict, systemImage: model.watchdogIsSevere
                  ? "exclamationmark.octagon.fill" : "gauge.with.needle")
                .font(.title3.weight(.semibold))
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(model.watchdogIsSevere ? .red.opacity(0.25) : .orange.opacity(0.2),
                            in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

@Observable public final class ChargeViewModel {
    public var targetSOCText = "—"
    public var timeRemainingText = "—"
    public var actualKWText = "0"
    public var expectedKWText = "—"
    public var ratio = 1.0
    public var ratioIsHealthy = true
    public var socText = "—"
    public var cellTempText = "—"
    public var energyAddedText = "0.0 kWh"
    public var watchdogText: String?
    public var watchdogIsSevere = false

    public init() {}

    public func bind(states: AsyncStream<VehicleState>) {
        Task { @MainActor in
            for await s in states where s.isDCFastCharging.value {
                actualKWText = String(Int(s.chargePowerKW.value.rounded()))
                socText = "\(Int(s.socPercent.value.rounded()))%"
                cellTempText = "\(Int(s.cellTempMaxC.value.rounded()))°"
            }
        }
    }

    /// Fed by the engine's charge tick (target, expected kW, watchdog verdicts).
    public func update(targetSOC: Double, secondsToTarget: Double,
                       expectedKW: Double, ratio: Double,
                       energyAddedKWh: Double,
                       watchdog: (text: String, severe: Bool)?) {
        targetSOCText = "\(Int(targetSOC.rounded()))%"
        let m = Int(secondsToTarget / 60), s = Int(secondsToTarget.truncatingRemainder(dividingBy: 60))
        timeRemainingText = String(format: "%d:%02d", m, s)
        expectedKWText = String(Int(expectedKW.rounded()))
        self.ratio = ratio
        ratioIsHealthy = ratio >= 0.9
        energyAddedText = String(format: "%.1f kWh", energyAddedKWh)
        watchdogText = watchdog?.text
        watchdogIsSevere = watchdog?.severe ?? false
    }
}
