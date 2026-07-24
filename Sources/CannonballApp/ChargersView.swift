import SwiftUI
import MapKit
import CannonballCore

/// Third-party charger finder backed by the DOE Alternative Fuels Data
/// Center: map + list of chargers around the car, filterable by speed and
/// public/private access. The backup plan when the Supercharger spacing
/// gets scary.
struct ChargersView: View {
    let model: AppModel
    @AppStorage("nrelApiKey") private var apiKey = "DEMO_KEY"
    @AppStorage("chargersDCOnly") private var dcFastOnly = true
    @AppStorage("chargersPublicOnly") private var publicOnly = true
    @AppStorage("chargersRadius") private var radiusMi = 25.0

    @State private var stations: [AFDCStation] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var center: CLLocationCoordinate2D?
    @State private var position: MapCameraPosition = .automatic
    @State private var selectedID: Int?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                chargerMap
                filterBar
                Divider()
                stationList
            }
            .navigationTitle("Chargers")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                Button {
                    Task { await load() }
                } label: {
                    if loading { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(loading)
            }
            .task { await load() }
        }
    }

    // MARK: map

    private var chargerMap: some View {
        Map(position: $position, selection: $selectedID) {
            if let center {
                Annotation("", coordinate: center) {
                    Image(systemName: "car.fill")
                        .font(.title3).foregroundStyle(.cyan).shadow(radius: 2)
                }
            }
            ForEach(stations) { station in
                Marker(station.stationName,
                       systemImage: station.dcFastCount > 0 ? "bolt.fill" : "powerplug",
                       coordinate: CLLocationCoordinate2D(latitude: station.latitude,
                                                          longitude: station.longitude))
                    .tint(markerColor(station))
                    .tag(station.id)
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .frame(height: 300)
    }

    private func markerColor(_ s: AFDCStation) -> Color {
        if !s.isPublic { return .gray }
        return s.dcFastCount > 0 ? .green : .blue
    }

    // MARK: filters

    private var filterBar: some View {
        HStack(spacing: 10) {
            Picker("Speed", selection: $dcFastOnly) {
                Text("DC fast").tag(true)
                Text("All levels").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 180)
            Toggle(isOn: $publicOnly) { Text("Public").font(.caption) }
                .toggleStyle(.button)
            Picker("Radius", selection: $radiusMi) {
                Text("10 mi").tag(10.0)
                Text("25 mi").tag(25.0)
                Text("50 mi").tag(50.0)
            }
            .pickerStyle(.menu)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .onChange(of: dcFastOnly) { _, _ in Task { await load() } }
        .onChange(of: publicOnly) { _, _ in Task { await load() } }
        .onChange(of: radiusMi) { _, _ in Task { await load() } }
    }

    // MARK: list

    private var stationList: some View {
        List(selection: $selectedID) {
            if let errorText {
                Text(errorText).foregroundStyle(.red).font(.callout)
            }
            if stations.isEmpty && !loading && errorText == nil {
                Text("No chargers found in \(Int(radiusMi)) mi with these filters.")
                    .foregroundStyle(.secondary)
            }
            ForEach(stations) { station in
                stationRow(station).tag(station.id)
            }
        }
        .listStyle(.plain)
    }

    private func stationRow(_ s: AFDCStation) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Circle().fill(markerColor(s)).frame(width: 8, height: 8)
                Text(s.stationName).font(.subheadline.weight(.semibold)).lineLimit(1)
                if !s.isPublic {
                    Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.orange)
                }
                Spacer()
                if let d = s.distance {
                    Text(String(format: "%.1f mi", d))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                if s.dcFastCount > 0 {
                    Label("\(s.dcFastCount) DC", systemImage: "bolt.fill")
                        .foregroundStyle(.green)
                }
                if s.level2Count > 0 {
                    Label("\(s.level2Count) L2", systemImage: "powerplug")
                        .foregroundStyle(.blue)
                }
                if !s.connectorNames.isEmpty {
                    Text(s.connectorNames.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            HStack(spacing: 8) {
                if let network = s.evNetwork { Text(network) }
                if let hours = s.accessDaysTime {
                    Text(hours).lineLimit(1)
                }
            }
            .font(.caption2).foregroundStyle(.tertiary)
            if let pricing = s.evPricing {
                Text(pricing).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: data

    private func load() async {
        loading = true
        errorText = nil
        defer { loading = false }
        guard let coordinate = await model.currentCarCoordinate() else {
            errorText = "No car location yet. Connect Tessie in Settings."
            return
        }
        center = coordinate
        position = .region(MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: radiusMi * 1609 * 1.6,
            longitudinalMeters: radiusMi * 1609 * 1.6))
        do {
            stations = try await AFDCClient.nearest(
                latitude: coordinate.latitude, longitude: coordinate.longitude,
                radiusMi: radiusMi,
                level: dcFastOnly ? .dcFast : .all,
                publicOnly: publicOnly,
                apiKey: apiKey.isEmpty ? "DEMO_KEY" : apiKey)
                .sorted { ($0.distance ?? 999) < ($1.distance ?? 999) }
        } catch {
            stations = []
            errorText = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}
