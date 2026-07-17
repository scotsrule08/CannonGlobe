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
                planColumn(title: "TESLA NAV", rows: model.teslaRows, tint: .secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private var headline: some View {
        Group {
            if let delta = model.headlineDelta {
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
        public var totalText: String?
    }

    public var optimizedRows: [StopRow] = []
    public var teslaRows: [StopRow] = []
    public var headlineDelta: String?
    public var siteNames: [String: String] = [:]

    public init() {}

    public func update(optimized: TripPlan, teslaNav: TripPlan?,
                       siteNames: [String: String]) {
        self.siteNames = siteNames
        optimizedRows = rows(for: optimized)
        teslaRows = teslaNav.map(rows(for:)) ?? []
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
                detail: "arr \(Int(stop.arrivalSOC))% · chg \(Int(stop.chargeSeconds / 60)) min → \(Int(stop.departureSOC))%",
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
        guard let stop = plan.stops.first, let leg = plan.legs.first else {
            nextStopName = "→ Destination"
            return
        }
        nextStopName = siteNames[stop.siteID] ?? stop.siteID
        arrivalSOCText = "\(Int(stop.arrivalSOC))%"
        arrivalSOCIsHealthy = stop.arrivalSOC >= 5
        minutesToStopText = "\(Int(leg.trafficDriveSeconds / 60))"
    }
}
