import SwiftUI
import CoreLocation
import CannonballCore

/// Live vehicle status straight from Tessie — no corridor planning involved,
/// so every number here is real regardless of where the car is.
struct CarView: View {
    let model: AppModel
    @State private var snap: AppModel.CarSnapshot?
    @State private var address: String?
    @State private var geocodedCoord: CLLocationCoordinate2D?

    var body: some View {
        NavigationStack {
            Form {
                if let cloud = snap?.cloud {
                    vehicleSection(cloud)
                    locationSection(cloud)
                    navigationSection(cloud)
                    batterySection(cloud)
                } else {
                    Section {
                        Label("Waiting for vehicle data. Check credentials in Settings.",
                              systemImage: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Car")
            .task {
                while !Task.isCancelled {
                    let s = await model.carSnapshot()
                    snap = s
                    if let cloud = s.cloud { await geocodeIfNeeded(cloud) }
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
    }

    // MARK: sections

    private func vehicleSection(_ cloud: CloudVehicleState) -> some View {
        Section("Vehicle") {
            if let name = cloud.displayName { LabeledContent("Name", value: name) }
            LabeledContent("Model", value: modelLine(cloud))
            if let odo = cloud.odometerMi {
                LabeledContent("Odometer", value: "\(Int(odo).formatted()) mi")
            }
        }
    }

    private func locationSection(_ cloud: CloudVehicleState) -> some View {
        Section("Location") {
            LabeledContent("Address", value: address ?? "Locating…")
            LabeledContent("Coordinates", value: String(format: "%.4f, %.4f",
                                                        cloud.latitude, cloud.longitude))
            if let speed = cloud.speedMph {
                LabeledContent("Speed", value: "\(Int(speed)) mph")
            }
            let age = Int(Date().timeIntervalSince(cloud.timestamp))
            LabeledContent("Updated", value: age < 5 ? "just now" : "\(age)s ago")
        }
    }

    @ViewBuilder
    private func navigationSection(_ cloud: CloudVehicleState) -> some View {
        Section("Navigation") {
            // The API keeps serving a finished route at 0 mi — treat as none.
            if let dest = cloud.activeRouteDestination,
               (cloud.activeRouteMilesToArrival ?? 0) > 0.5 {
                LabeledContent("Destination", value: dest)
                if let mins = cloud.activeRouteMinutesToArrival {
                    LabeledContent("ETA", value: etaText(minutes: mins))
                }
                if let miles = cloud.activeRouteMilesToArrival {
                    LabeledContent("Distance", value: String(format: "%.0f mi", miles))
                }
                if let soc = cloud.activeRouteEnergyAtArrival {
                    LabeledContent("SOC at arrival (car's estimate)",
                                   value: "\(Int(soc))%")
                }
            } else {
                Text("No active navigation")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func batterySection(_ cloud: CloudVehicleState) -> some View {
        Section("Battery") {
            LabeledContent("State of charge", value: socText(cloud))
            LabeledContent("Rated range", value: "\(Int(cloud.ratedRangeMi)) mi")
            if let limit = cloud.chargeLimitSOC {
                LabeledContent("Charge limit", value: "\(Int(limit))%")
            }
            LabeledContent("Battery temp", value: packTempText(cloud))
            if let ideal = snap?.pack.idealSuperchargeCellTempC {
                LabeledContent("Ideal supercharging temp",
                               value: "\(Int(ideal.lowerBound))-\(Int(ideal.upperBound)) °C")
            }
            LabeledContent("Charging", value: chargingText(cloud))
            if let heater = cloud.batteryHeaterOn {
                LabeledContent("Battery heater", value: heater ? "On" : "Off")
            }
        }
    }

    // MARK: formatting

    private func modelLine(_ cloud: CloudVehicleState) -> String {
        var parts: [String] = []
        if let year = Self.modelYear(fromVIN: SecretsStore.tessieVIN ?? "") {
            parts.append(String(year))
        }
        parts.append("Tesla")
        parts.append(cloud.modelName ?? Self.modelName(cloud.carType))
        if let trim = cloud.trimBadging?.uppercased(), !trim.isEmpty {
            parts.append(trim)
        }
        return parts.joined(separator: " ")
    }

    private func socText(_ cloud: CloudVehicleState) -> String {
        var text = "\(Int(cloud.socPercent))%"
        if let usable = cloud.usableBatteryLevel, Int(usable) != Int(cloud.socPercent) {
            text += " (usable \(Int(usable))%)"
        }
        return text
    }

    private func packTempText(_ cloud: CloudVehicleState) -> String {
        if let lo = cloud.moduleTempMinC, let hi = cloud.moduleTempMaxC {
            return String(format: "%.0f-%.0f °C", lo, hi)
        }
        return "Not reported yet"
    }

    private func chargingText(_ cloud: CloudVehicleState) -> String {
        var text = cloud.chargingState
        if let kW = cloud.chargerPowerKW, kW > 0 {
            text += String(format: " · %.0f kW", kW)
        }
        if let mins = cloud.minutesToFullCharge, mins > 0 {
            text += " · \(Int(mins)) min to limit"
        }
        return text
    }

    private func etaText(minutes: Double) -> String {
        let arrival = Date().addingTimeInterval(minutes * 60)
        let time = arrival.formatted(date: .omitted, time: .shortened)
        return "\(Int(minutes)) min (\(time))"
    }

    // MARK: geocoding — throttled to significant moves

    private func geocodeIfNeeded(_ cloud: CloudVehicleState) async {
        guard cloud.latitude != 0 || cloud.longitude != 0 else { return }
        let here = CLLocation(latitude: cloud.latitude, longitude: cloud.longitude)
        if let prev = geocodedCoord {
            let moved = here.distance(from: CLLocation(latitude: prev.latitude,
                                                       longitude: prev.longitude))
            guard moved > 250 else { return }
        }
        geocodedCoord = here.coordinate
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(here).first
        else { return }
        address = [placemark.name ?? placemark.thoroughfare,
                   placemark.locality, placemark.administrativeArea]
            .compactMap { $0 }.joined(separator: ", ")
    }

    // MARK: static maps

    static func modelName(_ carType: String?) -> String {
        switch carType?.lowercased() {
        case "model3", "lychee": return "Model 3"
        case "modely", "tamarind": return "Model Y"
        case "models": return "Model S"
        case "modelx": return "Model X"
        case "cybertruck": return "Cybertruck"
        default: return carType.map { "Model \($0.uppercased())" } ?? "Model"
        }
    }

    /// VIN position 10 encodes model year (2024=R, 2025=S, 2026=T…).
    static func modelYear(fromVIN vin: String) -> Int? {
        guard vin.count == 17 else { return nil }
        let codes = "ABCDEFGHJKLMNPRSTVWXY123456789"
        let char = vin[vin.index(vin.startIndex, offsetBy: 9)]
        guard let offset = codes.firstIndex(of: char).map({
            codes.distance(from: codes.startIndex, to: $0)
        }) else { return nil }
        return 2010 + offset
    }
}
