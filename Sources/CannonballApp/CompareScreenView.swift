import SwiftUI
import CannonballCore

/// Compare screen: Tesla Nav plan vs app-optimized plan, per-stop, with one
/// headline delta (docs §2.5).
public struct CompareScreenView: View {
    @Bindable var model: CompareViewModel

    public init(model: CompareViewModel) { self.model = model }

    public var body: some View {
        VStack(spacing: 16) {
            headline
            HStack(alignment: .top, spacing: 12) {
                planColumn(title: "APP PLAN", rows: model.optimizedRows, tint: .cyan)
                if model.teslaPlanAvailable {
                    planColumn(title: "TESLA NAV", rows: model.teslaRows, tint: .secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private var headline: some View {
        Group {
            if !model.teslaPlanAvailable {
                Label("No Tesla Nav charging stop visible to compare",
                      systemImage: "eye.slash")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            } else if let delta = model.headlineDelta {
                Label(delta, systemImage: "bolt.badge.clock.fill")
                    .font(.title.weight(.black))
                    .foregroundStyle(.cyan)
            } else {
                Label("Plans agree", systemImage: "checkmark.circle")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.green)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func planColumn(title: String, rows: [CompareViewModel.StopRow],
                            tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.bold)).foregroundStyle(tint)
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name).font(.subheadline.weight(.semibold))
                    Text(row.detail).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if let amenity = row.amenity {
                        Label(amenity, systemImage: "fork.knife")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
            if let total = rows.first?.totalText {
                Text(total).font(.headline.monospacedDigit()).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

@Observable public final class CompareViewModel {
    public struct StopRow: Identifiable {
        public var id: String
        public var name: String
        public var detail: String       // "arr 8% · chg 14 min → 54%"
        public var amenity: String?     // "Dunkin' · 4:30am-10:00pm daily"
        public var totalText: String?
    }

    public var optimizedRows: [StopRow] = []
    public var teslaRows: [StopRow] = []
    public var headlineDelta: String?
    public var teslaPlanAvailable = false
    public var siteNames: [String: String] = [:]
    public var siteAmenities: [String: String] = [:]

    public init() {}

    public func update(optimized: TripPlan, teslaNav: TripPlan?,
                       siteNames: [String: String]) {
        self.siteNames = siteNames
        optimizedRows = rows(for: optimized)
        teslaRows = teslaNav.map(rows(for:)) ?? []
        teslaPlanAvailable = teslaNav != nil
        if let tesla = teslaNav {
            let delta = tesla.totalRemainingSeconds - optimized.totalRemainingSeconds
            headlineDelta = delta > 60
                ? "App plan is \(Self.hms(delta)) faster"
                : nil
        } else {
            headlineDelta = nil
        }
    }

    private func rows(for plan: TripPlan) -> [StopRow] {
        let total = "Total: \(Self.hms(plan.totalRemainingSeconds))"
        return plan.stops.enumerated().map { i, stop in
            StopRow(
                id: "\(stop.siteID)-\(i)",
                name: siteNames[stop.siteID] ?? stop.siteID,
                detail: "arr \(Int(stop.arrivalSOC))% · chg \(max(1, Int((stop.chargeSeconds / 60).rounded()))) min → \(Int(stop.departureSOC))%",
                amenity: siteAmenities[stop.siteID],
                totalText: i == 0 ? total : nil)
        }
    }

    static func hms(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600, m = (Int(seconds) % 3600) / 60
        return h > 0 ? "\(h) h \(m) min" : "\(m) min"
    }
}

extension DashboardViewModel {
    /// Plan-derived fields for the drive screen.
    public func update(plan: TripPlan, siteNames: [String: String]) {
        arrivalLabel = "ARRIVE SOC"; minutesLabel = "MIN TO STOP"
        guard let stop = plan.stops.first, let leg = plan.legs.first else {
            nextStopName = "→ Destination"
            return
        }
        nextStopName = siteNames[stop.siteID] ?? stop.siteID
        arrivalSOCText = "\(Int(stop.arrivalSOC))%"
        arrivalSOCIsHealthy = stop.arrivalSOC >= 5
        minutesToStopText = "\(Int(leg.trafficDriveSeconds / 60))"
    }

    /// Off the cannonball corridor: the DP plan is meaningless, so show the
    /// car's own state and (when navigating) its own arrival estimate.
    public func update(offCorridor cloud: CloudVehicleState?) {
        whPerMiText = "—"; deltaVsTeslaText = "—"; efficiencyOnPlan = true
        guard let cloud else {
            nextStopName = "Off corridor"
            return
        }
        if let dest = cloud.activeRouteDestination {
            let parts = dest.components(separatedBy: ", ")
            nextStopName = parts.prefix(2).joined(separator: ", ")
            arrivalLabel = "ARRIVE SOC"; minutesLabel = "MIN TO ARRIVE"
            if let soc = cloud.activeRouteEnergyAtArrival {
                arrivalSOCText = "\(Int(soc))%"
                arrivalSOCIsHealthy = soc >= 10
            } else {
                arrivalSOCText = "—"
            }
            minutesToStopText = cloud.activeRouteMinutesToArrival.map { "\(Int($0))" } ?? "—"
        } else {
            nextStopName = "Off corridor"
            arrivalLabel = "SOC NOW"; minutesLabel = "MI RANGE"
            arrivalSOCText = "\(Int(cloud.socPercent))%"
            arrivalSOCIsHealthy = cloud.socPercent >= 20
            minutesToStopText = "\(Int(cloud.ratedRangeMi))"
        }
    }
}
