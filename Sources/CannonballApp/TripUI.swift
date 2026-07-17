import SwiftUI
import MapKit
import CannonballCore

/// Drive tab = the glanceable dashboard plus trip controls: set any
/// destination and the corridor planner rebuilds around the real route.
struct DriveScreen: View {
    let model: AppModel
    let dashboard: DashboardViewModel
    @State private var showTripSheet = false
    @State private var showFullMap = false
    @State private var showRunLog = false
    @State private var navShareState: NavShareState = .idle

    enum NavShareState: Equatable { case idle, sending, sent, failed(String) }

    var body: some View {
        VStack(spacing: 0) {
            DashboardView(model: dashboard)
            tripBar
        }
        .sheet(isPresented: $showTripSheet) { TripSearchSheet(model: model) }
        .sheet(isPresented: $showRunLog) { RunLogSheet(model: model) }
        #if os(iOS)
        .fullScreenCover(isPresented: $showFullMap) { FullTripMapView(model: model) }
        #else
        .sheet(isPresented: $showFullMap) { FullTripMapView(model: model) }
        #endif
    }

    @ViewBuilder private var tripBar: some View {
        if let name = dashboard.tripDestinationName {
            VStack(spacing: 10) {
                if let data = model.tripMapData() {
                    TripMapView(data: data, compact: true)
                        .frame(height: 165)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .onTapGesture { showFullMap = true }
                }
                if case .failed(let reason) = navShareState {
                    Text(reason).font(.caption).foregroundStyle(.red)
                }
                HStack(spacing: 10) {
                    Label(name, systemImage: "flag.checkered")
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Button { sendToCarNav() } label: { navButtonLabel }
                        .buttonStyle(.bordered)
                        .disabled(navShareState == .sending)
                    Button { showRunLog = true } label: {
                        Image(systemName: "list.bullet.clipboard")
                    }
                    .buttonStyle(.bordered)
                    Button("End", role: .destructive) { model.endTrip() }
                        .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 12)
        } else {
            Button {
                showTripSheet = true
            } label: {
                Label("Set Trip Destination", systemImage: "mappin.and.ellipse")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 24).padding(.bottom, 12)
        }
    }

    @ViewBuilder private var navButtonLabel: some View {
        switch navShareState {
        case .idle, .failed: Image(systemName: "paperplane.fill")
        case .sending: ProgressView().controlSize(.small)
        case .sent: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    /// Share the next planned stop into the car's nav — also the reliable
    /// trigger for on-route preconditioning.
    private func sendToCarNav() {
        navShareState = .sending
        Task {
            if let error = await model.sendNextStopToCarNav() {
                navShareState = .failed(error)
            } else {
                navShareState = .sent
                try? await Task.sleep(for: .seconds(4))
                if navShareState == .sent { navShareState = .idle }
            }
        }
    }
}

struct TripSearchSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var completer = DestinationCompleter()
    @State private var query = ""
    @State private var planning = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            List {
                if planning {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Routing and loading Superchargers…")
                            .foregroundStyle(.secondary)
                    }
                }
                if let errorText {
                    Text(errorText).foregroundStyle(.red)
                }
                ForEach(completer.results, id: \.self) { completion in
                    Button {
                        select(completion)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(completion.title)
                            if !completion.subtitle.isEmpty {
                                Text(completion.subtitle)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(planning)
                }
            }
            .searchable(text: $query, prompt: "Where to?")
            .onChange(of: query) { _, new in completer.update(query: new) }
            .navigationTitle("Road Trip")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .preferredColorScheme(.dark)
    }

    private func select(_ completion: MKLocalSearchCompletion) {
        planning = true; errorText = nil
        Task {
            do {
                let response = try await MKLocalSearch(request: .init(completion: completion)).start()
                guard let item = response.mapItems.first else { throw TripError.noRoute }
                try await model.startTrip(to: item.placemark.coordinate,
                                          named: completion.title)
                dismiss()
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                planning = false
            }
        }
    }
}

/// Thin observable wrapper over MKLocalSearchCompleter.
@Observable
final class DestinationCompleter: NSObject, MKLocalSearchCompleterDelegate {
    var results: [MKLocalSearchCompletion] = []
    @ObservationIgnored private lazy var completer: MKLocalSearchCompleter = {
        let c = MKLocalSearchCompleter()
        c.delegate = self
        c.resultTypes = [.address, .pointOfInterest]
        return c
    }()

    func update(query: String) {
        if query.isEmpty { results = [] } else { completer.queryFragment = query }
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        results = completer.results
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        results = []
    }
}
