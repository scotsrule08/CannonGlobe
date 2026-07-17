import Foundation
import CoreLocation

/// Compressed elevation profile: cumulative meters at fixed distance steps.
public struct ElevationProfile: Codable, Sendable {
    public var stepMeters: Double
    public var elevationsM: [Float]
    public init(stepMeters: Double, elevationsM: [Float]) {
        self.stepMeters = stepMeters; self.elevationsM = elevationsM
    }
    public var totalClimbM: Double {
        zip(elevationsM, elevationsM.dropFirst())
            .reduce(0) { $0 + max(0, Double($1.1 - $1.0)) }
    }
}

public struct WindForecast: Codable, Sendable {
    public var headwindMps: Double     // + headwind, − tailwind, leg-averaged
    public var crosswindMps: Double
    public var gustFactor: Double      // gust / sustained
    public var sigmaMps: Double        // forecast error stdev
    public init(headwindMps: Double, crosswindMps: Double,
                gustFactor: Double = 1.3, sigmaMps: Double = 1.5) {
        self.headwindMps = headwindMps; self.crosswindMps = crosswindMps
        self.gustFactor = gustFactor; self.sigmaMps = sigmaMps
    }
}

public struct RouteLeg: Codable, Sendable, Identifiable {
    public var id: String                       // "\(fromID)->\(toID)"
    public var fromSiteID: String               // "origin" for Redball Garage
    public var toSiteID: String                 // "dest" for the Portofino
    public var distanceMi: Double
    public var elevation: ElevationProfile
    public var wind: WindForecast
    public var ambientTempC: Double
    public var trafficDriveSeconds: Double      // MapKit traffic-aware ETA
    public var avgSpeedMps: Double

    // Filled by EnergyModel
    public var predictedKWh: Double
    public var predictedSigmaKWh: Double

    // Filled by the planner
    public var requiredDepartureSOC: Double
    public var predictedArrivalSOC: Double

    public init(fromSiteID: String, toSiteID: String, distanceMi: Double,
                elevation: ElevationProfile, wind: WindForecast, ambientTempC: Double,
                trafficDriveSeconds: Double, avgSpeedMps: Double,
                predictedKWh: Double = 0, predictedSigmaKWh: Double = 0,
                requiredDepartureSOC: Double = 0, predictedArrivalSOC: Double = 0) {
        self.id = "\(fromSiteID)->\(toSiteID)"
        self.fromSiteID = fromSiteID; self.toSiteID = toSiteID
        self.distanceMi = distanceMi; self.elevation = elevation; self.wind = wind
        self.ambientTempC = ambientTempC; self.trafficDriveSeconds = trafficDriveSeconds
        self.avgSpeedMps = avgSpeedMps; self.predictedKWh = predictedKWh
        self.predictedSigmaKWh = predictedSigmaKWh
        self.requiredDepartureSOC = requiredDepartureSOC
        self.predictedArrivalSOC = predictedArrivalSOC
    }
}

public struct PlannedStop: Codable, Sendable {
    public var siteID: String
    public var arrivalSOC: Double
    public var departureSOC: Double
    public var chargeSeconds: Double
    public var detourSeconds: Double
    public var expectedQueueSeconds: Double
    public init(siteID: String, arrivalSOC: Double, departureSOC: Double,
                chargeSeconds: Double, detourSeconds: Double, expectedQueueSeconds: Double) {
        self.siteID = siteID; self.arrivalSOC = arrivalSOC; self.departureSOC = departureSOC
        self.chargeSeconds = chargeSeconds; self.detourSeconds = detourSeconds
        self.expectedQueueSeconds = expectedQueueSeconds
    }
}

/// A complete plan from current position to destination. Two live instances
/// exist at all times: the Tesla-Nav-pinned plan and the app-optimized plan.
public struct TripPlan: Codable, Sendable {
    public var generatedAt: Date
    public var legs: [RouteLeg]
    public var stops: [PlannedStop]
    public var totalRemainingSeconds: Double
    public init(generatedAt: Date, legs: [RouteLeg], stops: [PlannedStop],
                totalRemainingSeconds: Double) {
        self.generatedAt = generatedAt; self.legs = legs; self.stops = stops
        self.totalRemainingSeconds = totalRemainingSeconds
    }
}
