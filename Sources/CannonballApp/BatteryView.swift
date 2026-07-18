import SwiftUI
import Charts
import CannonballCore

/// Battery tab: the pack's live vitals from the fused state (CAN when the S3XY
/// bridge is streaming, cloud otherwise). Every row is tagged with its source
/// so a suspect CAN value is attributable at a glance.
struct BatteryView: View {
    let model: AppModel
    @State private var snap: AppModel.BatterySnapshot?

    private var pack: PackProfile { snap?.pack ?? .us2025PremiumRWD }

    var body: some View {
        NavigationStack {
            Form {
                sourceSection
                if let state = snap?.state {
                    chargeSection(state)
                    thermalSection(state)
                    powerSection(state)
                    capacitySection(state)
                } else {
                    Section {
                        Label("Waiting for vehicle data.", systemImage: "hourglass")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Battery")
            .task {
                while !Task.isCancelled {
                    snap = await model.batterySnapshot()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    // MARK: sections

    private var sourceSection: some View {
        Section {
            HStack(spacing: 10) {
                Circle().fill(snap?.canStreaming == true ? .green : .orange)
                    .frame(width: 10, height: 10)
                Text(snap?.canStreaming == true
                     ? "Live CAN via S3XY Commander"
                     : "Cloud telemetry (CAN bridge off)")
                    .font(.callout)
            }
        }
    }

    private func chargeSection(_ s: VehicleState) -> some View {
        Section("State of charge") {
            row("SOC", String(format: "%.1f%%", s.socPercent.value), s.socPercent.source)
            if let limit = snap?.cloud?.chargeLimitSOC {
                LabeledContent("Charge limit", value: "\(Int(limit))%")
            }
            row("Usable remaining", String(format: "%.1f kWh", s.usableKWhRemaining.value),
                s.usableKWhRemaining.source)
            LabeledContent("Charging") {
                Text(chargingText(s)).foregroundStyle(s.isDCFastCharging.value ? .green : .secondary)
            }
        }
    }

    private func thermalSection(_ s: VehicleState) -> some View {
        let band = pack.idealSuperchargeCellTempC
        return Section {
            cellTempBar(s, band: band)
            row("Cell temp min", tempText(s.cellTempMinC.value), s.cellTempMinC.source)
            row("Cell temp avg", tempText(s.cellTempAvgC.value), s.cellTempAvgC.source)
            row("Cell temp max", tempText(s.cellTempMaxC.value), s.cellTempMaxC.source)
            row("Ambient", tempText(s.ambientTempC.value), s.ambientTempC.source)
            LabeledContent("Preconditioning") {
                Text(preconditionText(s.precondition.value))
                    .foregroundStyle(preconditionColor(s.precondition.value))
            }
        } header: {
            Text("Thermal")
        } footer: {
            Text("Ideal supercharging window: \(Int(band.lowerBound))–\(Int(band.upperBound)) °C. The green band on the bar is that target.")
        }
    }

    private func powerSection(_ s: VehicleState) -> some View {
        Section("Pack & power") {
            row("Pack voltage", String(format: "%.1f V", s.packVoltage.value), s.packVoltage.source)
            row("Pack current", String(format: "%.1f A", s.packCurrentA.value), s.packCurrentA.source)
            let kW = s.packPowerKW
            LabeledContent("Pack power",
                           value: String(format: "%.1f kW %@", abs(kW), kW < 0 ? "(charging)" : ""))
            row("BMS max regen", String(format: "%.0f kW", s.bmsMaxChargeKW.value),
                s.bmsMaxChargeKW.source)
            row("BMS max discharge", String(format: "%.0f kW", s.bmsMaxDischargeKW.value),
                s.bmsMaxDischargeKW.source)
        }
    }

    private func capacitySection(_ s: VehicleState) -> some View {
        Section {
            LabeledContent("Pack profile", value: pack.name)
            LabeledContent("Usable capacity (new)", value: String(format: "%.1f kWh", pack.usableKWh))
            LabeledContent("Chemistry", value: pack.chemistry.rawValue.uppercased())
            if let cloud = snap?.cloud, let range = cloud.ratedRangeMi as Double? {
                LabeledContent("Rated range", value: "\(Int(range)) mi")
            }
        } header: {
            Text("Capacity")
        } footer: {
            Text("Usable-when-new is the pack prior; the planner uses a degraded value refined by live learning.")
        }
    }

    // MARK: bits

    @ViewBuilder
    private func cellTempBar(_ s: VehicleState, band: ClosedRange<Double>) -> some View {
        let lo = min(band.lowerBound, s.cellTempMinC.value) - 5
        let hi = max(band.upperBound, s.cellTempMaxC.value) + 5
        Chart {
            RectangleMark(xStart: .value("lo", band.lowerBound),
                          xEnd: .value("hi", band.upperBound))
                .foregroundStyle(.green.opacity(0.18))
            BarMark(xStart: .value("min", s.cellTempMinC.value),
                    xEnd: .value("max", s.cellTempMaxC.value),
                    y: .value("cells", "cells"), height: 16)
                .foregroundStyle(.cyan)
            RuleMark(x: .value("avg", s.cellTempAvgC.value))
                .foregroundStyle(.white)
        }
        .chartXScale(domain: lo...hi)
        .chartYAxis(.hidden)
        .chartXAxisLabel("Cell temp °C")
        .frame(height: 64)
    }

    private func row(_ label: String, _ value: String, _ source: SourceTag) -> some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                Text(value).monospacedDigit()
                Text(sourceBadge(source))
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(sourceColor(source).opacity(0.22), in: Capsule())
                    .foregroundStyle(sourceColor(source))
            }
        }
    }

    private func sourceBadge(_ s: SourceTag) -> String {
        switch s {
        case .can: "CAN"
        case .tessieStream, .tessieREST, .fleetAPI: "CLOUD"
        case .phoneGPS: "GPS"
        case .deadReckoned: "EST"
        }
    }
    private func sourceColor(_ s: SourceTag) -> Color {
        switch s {
        case .can: .green
        case .deadReckoned: .orange
        default: .secondary
        }
    }

    private func tempText(_ c: Double) -> String {
        String(format: "%.1f °C  (%.0f °F)", c, c * 9 / 5 + 32)
    }
    private func chargingText(_ s: VehicleState) -> String {
        guard s.isDCFastCharging.value else { return "Not charging" }
        return String(format: "DC · %.0f kW", s.chargePowerKW.value)
    }
    private func preconditionText(_ p: PreconditionStatus) -> String {
        switch p {
        case .off: "Off"
        case .requested: "Requested"
        case .heating: "Heating"
        case .atTemperature: "At temperature"
        case .unavailable: "Unavailable"
        }
    }
    private func preconditionColor(_ p: PreconditionStatus) -> Color {
        switch p {
        case .heating, .atTemperature: .green
        case .requested: .orange
        default: .secondary
        }
    }
}
