import Foundation

/// Everything the physics layer needs to know about one battery pack variant.
/// See docs/01-battery-and-charge-curve.md for sourcing and confidence notes.
public struct PackProfile: Sendable {
    public enum Chemistry: String, Sendable { case nickel, lfp }

    public var name: String
    public var chemistry: Chemistry
    public var usableKWh: Double
    public var nominalVoltage: Double
    public var peakDCkW: Double
    /// (indicated SOC %, kW) anchors at 25 °C on an unshared V3+ stall.
    public var baseCurve: [(soc: Double, kW: Double)]
    /// (min cell °C, multiplier) — cold-side limit anchors.
    public var coldFactor: [(tempC: Double, factor: Double)]
    /// (max cell °C, multiplier) — hot-side limit anchors.
    public var hotFactor: [(tempC: Double, factor: Double)]
    /// Indicated SOC below which arrival is forbidden by the planner.
    public var bufferFloorSOC: Double

    /// 2025 US (Fremont) Model 3 RWD: software-range-locked Panasonic
    /// nickel-based pack. NOT the export-market CATL LFP — see docs §1.1.
    /// usableKWh is a prior; day-0 calibration overwrites it.
    public static let us2025RWDNickel = PackProfile(
        name: "2025 M3 RWD US (locked nickel)",
        chemistry: .nickel,
        usableKWh: 62.4,
        nominalVoltage: 346,
        peakDCkW: 170,
        baseCurve: [
            (0, 120), (5, 165), (10, 170), (15, 170), (20, 170), (25, 168),
            (30, 162), (40, 148), (50, 130), (60, 110), (70, 90), (80, 68),
            (90, 48), (97, 28), (100, 8),
        ],
        coldFactor: [(-10, 0.15), (0, 0.35), (10, 0.65), (20, 0.90), (25, 1.0), (45, 1.0)],
        hotFactor: [(45, 1.0), (50, 0.85), (55, 0.60), (60, 0.40)],
        bufferFloorSOC: 6.0
    )

    /// Fallback: CATL LFP60 (pre-Highland US / export-market base RWD).
    /// Selected only if the day-0 chemistry signature check demands it.
    public static let lfp60 = PackProfile(
        name: "M3 RWD CATL LFP60",
        chemistry: .lfp,
        usableKWh: 57.5,
        nominalVoltage: 345,
        peakDCkW: 170,
        baseCurve: [
            (0, 100), (5, 160), (10, 170), (20, 168), (30, 150), (40, 130),
            (50, 110), (57, 99), (70, 70), (80, 52), (90, 35), (97, 18), (100, 5),
        ],
        coldFactor: [(-10, 0.08), (0, 0.22), (10, 0.50), (20, 0.85), (25, 1.0), (45, 1.0)],
        hotFactor: [(45, 1.0), (50, 0.85), (55, 0.60), (60, 0.40)],
        bufferFloorSOC: 9.0   // LFP SOC estimation drift → bigger floor
    )

    /// Chemistry signature from live CAN: pack volts per cell group at a known
    /// SOC. Nickel ≈ 3.5–3.7 V/cell mid-SOC; LFP pins near 3.25–3.35 V.
    public static func detect(packVoltage: Double, socPercent: Double,
                              seriesGroups: Int = 96) -> PackProfile {
        let vPerCell = packVoltage / Double(seriesGroups)
        // Mid-SOC comparison is unambiguous between the chemistries.
        if socPercent > 20, socPercent < 90, vPerCell < 3.42 { return .lfp60 }
        return .us2025RWDNickel
    }
}
