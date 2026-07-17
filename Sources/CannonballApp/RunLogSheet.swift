import SwiftUI
import CannonballCore

/// The automatic logbook: planned vs actual for every stop, plus run totals.
struct RunLogSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var log: RunLog?

    var body: some View {
        NavigationStack {
            List {
                if let log {
                    summarySection(log)
                    stopsSection(log)
                } else {
                    Text("No run recorded yet. Start a trip and the logbook fills itself.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Run Log")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { Button("Done") { dismiss() } }
            .task {
                while !Task.isCancelled {
                    log = model.currentRunLog()
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func summarySection(_ log: RunLog) -> some View {
        Section(log.tripName) {
            LabeledContent("Departed",
                value: log.startedAt.formatted(date: .abbreviated, time: .shortened))
            LabeledContent("Start SOC", value: "\(Int(log.startSOC))%")
            let end = log.endedAt ?? Date()
            LabeledContent(log.endedAt == nil ? "Elapsed" : "Total",
                value: Self.hm(end.timeIntervalSince(log.startedAt)))
            if let baseline = log.baselineTotalSeconds {
                LabeledContent("First plan estimate", value: Self.hm(baseline))
            }
            let chargeTotal = log.stops.compactMap(\.chargeSeconds).reduce(0, +)
            if chargeTotal > 0 {
                LabeledContent("Time on plug", value: Self.hm(chargeTotal))
            }
        }
    }

    private func stopsSection(_ log: RunLog) -> some View {
        Section("Stops (\(log.stops.count))") {
            if log.stops.isEmpty {
                Text("No charge stops yet.").foregroundStyle(.secondary)
            }
            ForEach(log.stops) { stop in
                VStack(alignment: .leading, spacing: 3) {
                    Text(stop.siteName).font(.subheadline.weight(.semibold))
                    Text(actualLine(stop))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if let planned = plannedLine(stop) {
                        Text(planned)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func actualLine(_ stop: ChargeStopRecord) -> String {
        var parts = ["arr \(Int(stop.arrivalSOC))%"]
        if let secs = stop.chargeSeconds { parts.append("\(Int(secs / 60)) min") }
        if let dep = stop.departureSOC { parts.append("→ \(Int(dep))%") }
        if let kWh = stop.energyAddedKWh, kWh > 0 {
            parts.append(String(format: "%.0f kWh", kWh))
        }
        if let kW = stop.avgKW { parts.append(String(format: "%.0f kW avg", kW)) }
        if stop.endedAt == nil { parts.append("charging…") }
        return parts.joined(separator: " · ")
    }

    private func plannedLine(_ stop: ChargeStopRecord) -> String? {
        guard let arr = stop.plannedArrivalSOC, let dep = stop.plannedDepartureSOC,
              let secs = stop.plannedChargeSeconds else { return nil }
        return "plan: arr \(Int(arr))% · \(Int(secs / 60)) min · → \(Int(dep))%"
    }

    static func hm(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600, m = (Int(seconds) % 3600) / 60
        return h > 0 ? "\(h) h \(m) min" : "\(m) min"
    }
}
