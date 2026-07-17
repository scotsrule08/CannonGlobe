import Foundation

/// One recorded charge stop: what the plan called for vs what happened.
public struct ChargeStopRecord: Codable, Sendable, Identifiable {
    public var id: String
    public var siteID: String
    public var siteName: String
    public var startedAt: Date
    public var endedAt: Date?
    public var arrivalSOC: Double
    public var departureSOC: Double?
    public var energyAddedKWh: Double?
    public var plannedArrivalSOC: Double?
    public var plannedDepartureSOC: Double?
    public var plannedChargeSeconds: Double?

    public init(id: String, siteID: String, siteName: String, startedAt: Date,
                arrivalSOC: Double, plannedArrivalSOC: Double? = nil,
                plannedDepartureSOC: Double? = nil, plannedChargeSeconds: Double? = nil) {
        self.id = id; self.siteID = siteID; self.siteName = siteName
        self.startedAt = startedAt; self.arrivalSOC = arrivalSOC
        self.plannedArrivalSOC = plannedArrivalSOC
        self.plannedDepartureSOC = plannedDepartureSOC
        self.plannedChargeSeconds = plannedChargeSeconds
    }

    public var chargeSeconds: Double? {
        endedAt.map { $0.timeIntervalSince(startedAt) }
    }
    public var avgKW: Double? {
        guard let kWh = energyAddedKWh, let secs = chargeSeconds, secs > 60 else { return nil }
        return kWh / (secs / 3600)
    }
}

/// The automatic logbook for one run: departure state, every stop, and the
/// baseline the pace tracker measures against.
public struct RunLog: Codable, Sendable {
    public var tripName: String
    public var startedAt: Date
    public var startSOC: Double
    public var startOdometerMi: Double?
    /// First plan's projected total seconds — the pace baseline.
    public var baselineTotalSeconds: Double?
    public var stops: [ChargeStopRecord] = []
    public var endedAt: Date?

    public init(tripName: String, startedAt: Date, startSOC: Double,
                startOdometerMi: Double? = nil) {
        self.tripName = tripName; self.startedAt = startedAt
        self.startSOC = startSOC; self.startOdometerMi = startOdometerMi
    }
}
