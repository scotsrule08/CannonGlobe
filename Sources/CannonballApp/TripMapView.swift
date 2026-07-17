import SwiftUI
import MapKit
import CannonballCore

/// Route + chargers + car. Green numbered pins are planned stops (the number
/// is the planned arrival SOC); gray dots are pass-by fallback chargers.
struct TripMapView: View {
    let data: AppModel.TripMapData
    var compact: Bool

    var body: some View {
        Map(interactionModes: compact ? [] : .all) {
            MapPolyline(coordinates: data.route)
                .stroke(.cyan, lineWidth: 3)
            ForEach(data.stops) { pin in
                Annotation(compact ? "" : shortName(pin.name), coordinate: pin.coordinate) {
                    if let soc = pin.arrivalSOC {
                        ZStack {
                            Circle().fill(.green).frame(width: 18, height: 18)
                            Text("\(Int(soc))")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.black)
                        }
                    } else {
                        Circle().fill(.gray.opacity(0.65)).frame(width: 7, height: 7)
                    }
                }
                .annotationTitles(compact ? .hidden : .automatic)
            }
            if let car = data.car {
                Annotation("", coordinate: car) {
                    Image(systemName: "car.fill")
                        .font(.title3)
                        .foregroundStyle(.cyan)
                        .shadow(radius: 2)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
    }

    private func shortName(_ name: String) -> String {
        name.components(separatedBy: ",").first ?? name
    }
}

/// Fullscreen, interactive, self-refreshing version.
struct FullTripMapView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var data: AppModel.TripMapData?

    var body: some View {
        NavigationStack {
            Group {
                if let data {
                    TripMapView(data: data, compact: false)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(data?.destinationName ?? "Trip Map")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                Button("Done") { dismiss() }
            }
            .task {
                while !Task.isCancelled {
                    data = model.tripMapData()
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
