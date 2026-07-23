import SwiftUI
import Charts
import CannonballCore

/// Weather along the planned route, sampled every ~40 mi at each point's
/// PREDICTED ARRIVAL HOUR (not current conditions) — the same forecast the
/// energy model plans against.
struct WeatherView: View {
    let model: AppModel
    @State private var snap = AppModel.WeatherSnapshot()
    @State private var refreshing = false

    var body: some View {
        NavigationStack {
            Group {
                if snap.hasData {
                    List {
                        headlineSection
                        if !snap.points.isEmpty {
                            windSection
                            tempSection
                            precipSection
                        }
                        if !snap.elevation.isEmpty { elevationSection }
                        if !snap.stops.isEmpty { stopsSection }
                    }
                } else {
                    ContentUnavailableView(
                        "No route weather yet",
                        systemImage: "cloud.sun",
                        description: Text(snap.destinationName == nil
                            ? "Set a trip destination on the Drive tab and the forecast along your route appears here."
                            : "Fetching the forecast along your route…"))
                }
            }
            .navigationTitle("Weather")
            .toolbar {
                Button {
                    refreshing = true
                    Task {
                        await model.refreshWeatherNow()
                        snap = model.weatherSnapshot()
                        refreshing = false
                    }
                } label: {
                    if refreshing { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(refreshing)
            }
            .task {
                while !Task.isCancelled {
                    snap = model.weatherSnapshot()
                    try? await Task.sleep(for: .seconds(10))
                }
            }
        }
    }

    // MARK: sections

    private var headlineSection: some View {
        Section {
            if let worst = snap.points.max(by: { $0.headwindMph < $1.headwindMph }),
               worst.headwindMph > 5 {
                Label("Worst headwind \(Int(worst.headwindMph)) mph in \(Int(worst.milesFromHere)) mi",
                      systemImage: "wind")
                    .foregroundStyle(.orange)
            } else if let best = snap.points.min(by: { $0.headwindMph < $1.headwindMph }),
                      best.headwindMph < -5 {
                Label("Tailwind up to \(Int(-best.headwindMph)) mph ahead", systemImage: "wind")
                    .foregroundStyle(.green)
            } else {
                Label("Calm air along the route", systemImage: "wind")
                    .foregroundStyle(.secondary)
            }
            if let wet = snap.points.first(where: { $0.precipMmPerHour > 0.05 }) {
                Label("Rain starting in \(Int(wet.milesFromHere)) mi (\(precipWord(wet.precipMmPerHour)))",
                      systemImage: "cloud.rain")
                    .foregroundStyle(.cyan)
            }
        } header: {
            Text(snap.destinationName.map { "Ahead to \($0)" } ?? "Ahead")
        }
    }

    private var windSection: some View {
        Section {
            Chart(snap.points) { p in
                AreaMark(x: .value("Miles", p.milesFromHere),
                         y: .value("Headwind", p.headwindMph))
                    .foregroundStyle(p.headwindMph >= 0 ? .orange.opacity(0.35) : .green.opacity(0.35))
                LineMark(x: .value("Miles", p.milesFromHere),
                         y: .value("Headwind", p.headwindMph))
                    .foregroundStyle(.primary)
                    .interpolationMethod(.monotone)
            }
            .chartYAxisLabel("mph  (+ head / − tail)")
            .chartXAxisLabel("Miles from here")
            .frame(height: 180)
        } header: {
            Text("Wind along the route")
        } footer: {
            Text("Positive is a headwind (costs energy), negative is a tailwind. The planner already prices this into every leg.")
        }
    }

    private var tempSection: some View {
        Section("Temperature") {
            Chart(snap.points) { p in
                LineMark(x: .value("Miles", p.milesFromHere),
                         y: .value("°F", p.tempF))
                    .foregroundStyle(.cyan)
                    .interpolationMethod(.monotone)
            }
            .chartYAxisLabel("°F")
            .chartXAxisLabel("Miles from here")
            .frame(height: 140)
        }
    }

    @ViewBuilder
    private var precipSection: some View {
        let wet = snap.points.filter { $0.precipMmPerHour > 0.05 }
        Section {
            if wet.isEmpty {
                Label("Dry the whole way", systemImage: "sun.max")
                    .foregroundStyle(.green)
            } else {
                if let first = wet.first {
                    Label("Starts in \(Int(first.milesFromHere)) mi · \(precipWord(first.precipMmPerHour))",
                          systemImage: "cloud.rain")
                        .font(.callout).foregroundStyle(.cyan)
                }
                if let peak = wet.max(by: { $0.precipMmPerHour < $1.precipMmPerHour }) {
                    Text(String(format: "Heaviest %.1f mm/h at %d mi · about %d mi of wet road",
                                peak.precipMmPerHour, Int(peak.milesFromHere), wet.count * 40))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Chart(snap.points) { p in
                BarMark(x: .value("Miles", p.milesFromHere),
                        y: .value("mm/h", p.precipMmPerHour))
                    .foregroundStyle(.blue)
            }
            .chartYAxisLabel("mm/h")
            .chartXAxisLabel("Miles from here")
            .frame(height: 130)
        } header: {
            Text("Precipitation")
        } footer: {
            Text("Rain raises consumption and slows the plan (~3% per mm/h, capped at 15%). Both are already priced into the route.")
        }
    }

    private var elevationSection: some View {
        Section {
            Label(String(format: "%.0f ft of climbing ahead", snap.climbAheadFt),
                  systemImage: "mountain.2")
                .font(.callout)
                .foregroundStyle(snap.climbAheadFt > 3000 ? .orange : .secondary)
            Chart {
                ForEach(snap.elevation) { e in
                    AreaMark(x: .value("Miles", e.milesFromHere),
                             y: .value("ft", e.feet))
                        .foregroundStyle(.brown.opacity(0.35))
                    LineMark(x: .value("Miles", e.milesFromHere),
                             y: .value("ft", e.feet))
                        .foregroundStyle(.brown)
                        .interpolationMethod(.monotone)
                }
                ForEach(snap.stops) { stop in
                    RuleMark(x: .value("Stop", stop.milesFromHere))
                        .foregroundStyle(.green.opacity(0.55))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartYAxisLabel("Elevation (ft)")
            .chartXAxisLabel("Miles from here")
            .frame(height: 170)
        } header: {
            Text("Elevation")
        } footer: {
            Text("Green dashes are planned charging stops. Climbs cost energy and descents give it back through regen; the planner integrates the whole profile per leg.")
        }
    }

    private var stopsSection: some View {
        Section("At each planned stop") {
            ForEach(snap.stops) { stop in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(stop.name).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(Int(stop.milesFromHere)) mi")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        Label("\(Int(stop.tempF))°F", systemImage: "thermometer.medium")
                        Label(windLabel(stop.headwindMph),
                              systemImage: stop.headwindMph >= 0 ? "arrow.left.to.line" : "arrow.right.to.line")
                            .foregroundStyle(stop.headwindMph > 5 ? .orange
                                             : (stop.headwindMph < -5 ? .green : .secondary))
                        if stop.precipMmPerHour > 0.05 {
                            Label(precipWord(stop.precipMmPerHour), systemImage: "cloud.rain")
                                .foregroundStyle(.cyan)
                        }
                    }
                    .font(.caption)
                }
            }
        }
    }

    // MARK: bits

    private func windLabel(_ mph: Double) -> String {
        abs(mph) < 1 ? "calm"
            : String(format: "%.0f mph %@", abs(mph), mph >= 0 ? "head" : "tail")
    }

    private func precipWord(_ mmPerHour: Double) -> String {
        switch mmPerHour {
        case ..<0.5: "light"
        case ..<4: "moderate"
        default: "heavy"
        }
    }
}
