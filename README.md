# CannonGlobe — FSD Cannonball Co-Pilot

An iOS companion app for a pure-FSD cannonball run:

**Redball Garage (Manhattan, NY) → Portofino Hotel (Redondo Beach, CA)**
**Vehicle: 2025 Tesla Model 3 Rear-Wheel Drive (US / Fremont-built)**

The car drives itself. The app's job is to make every *other* decision better
than Tesla's built-in navigation: which Supercharger, how long to charge, when
to precondition, when to bail on a bad stall. A 4-minute suboptimal charge stop
is a mission failure; the app optimizes ruthlessly for total door-to-door time.

## Repository layout

| Path | Contents |
|---|---|
| `docs/01-battery-and-charge-curve.md` | Verified 2025 US Model 3 RWD pack specs and the SOC/temperature/site-limited charge-curve model |
| `docs/02-system-architecture.md` | System architecture, data-flow diagram (S3XY CAN → fusion → decision engine → UI), data models |
| `docs/03-decision-engine.md` | Recommendation engine algorithms: SOC target calculator, Supercharger scorer, charge watchdog, Tesla-Nav challenger |
| `docs/04-data-integrations-and-legal.md` | S3XY Commander / Panda protocol, Tessie + Fleet API, Supercharger data, ABRP, weather/wind; ToS & legal notes |
| `docs/05-implementation-plan-and-edge-cases.md` | Phased plan (MVP for the actual run → full vision) and edge-case handling |
| `Package.swift`, `Sources/` | Swift package: `CannonballCore` (models, telemetry clients, fusion, decision engine) + `CannonballApp` UI skeletons |
| `Tests/` | Unit tests for the charge-curve model and SOC target calculator |

## Core capabilities

- **Live CAN telemetry** from the Enhance Auto S3XY Commander (Panda protocol over Wi-Fi, 192.168.4.1): pack current/voltage, min/max/avg cell temps, BMS limits, true charge power, SOC.
- **Cloud telemetry** via Tessie (mirrored Fleet API + streaming) for location, drive/charge history, and calibration; graceful degradation when either source drops.
- **Charge-curve model** specific to the 2025 US RWD's software-locked nickel pack — SOC-, temperature-, and site-version-dependent, with live residual learning.
- **Charge watchdog**: actual kW vs expected kW every second; recommends stall-hop or site-hop with a concrete time delta.
- **Tesla Nav challenger**: independently scores the car's chosen Supercharger against alternatives on total-time (detour + charge to next-leg energy), and says exactly how many minutes the better plan saves.
- **Dynamic SOC targets**: never "charge to 80%" — charge to the minimum SOC that reaches the next optimal stop with a physics-based buffer (elevation, wind, temp, observed FSD efficiency).
- **Preconditioning intelligence** timed against arrival cell temperature, via Fleet API nav-to-SC trigger and (where exposed) Commander commands.

## Status

Specification + core-architecture skeleton. See
`docs/05-implementation-plan-and-edge-cases.md` for the build order targeting a
run-ready MVP.
