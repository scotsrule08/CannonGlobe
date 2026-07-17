# CannonGlobe — FSD Cannonball Co-Pilot

An iOS companion app for a pure-FSD cannonball run:

**Redball Garage (Manhattan, NY) → Portofino Hotel (Redondo Beach, CA)**
**Vehicle: 2025 Tesla Model 3 Premium RWD (US) — Panasonic 2170 NCA, 79 kWh usable, 250 kW peak, 363 mi EPA**

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
- **Charge-curve model** specific to the 2025 Premium RWD's 79 kWh NCA pack (brief 250 kW peak, aggressive taper) — SOC-, temperature-, and site-version-dependent, with live residual learning.
- **Charge watchdog**: actual kW vs expected kW every second; recommends stall-hop or site-hop with a concrete time delta.
- **Tesla Nav challenger**: independently scores the car's chosen Supercharger against alternatives on total-time (detour + charge to next-leg energy), and says exactly how many minutes the better plan saves.
- **Dynamic SOC targets**: never "charge to 80%" — charge to the minimum SOC that reaches the next optimal stop with a physics-based buffer (elevation, wind, temp, observed FSD efficiency).
- **Preconditioning intelligence** timed against arrival cell temperature, via Fleet API nav-to-SC trigger and (where exposed) Commander commands.

## Building the app

The repo is a Swift package (`CannonballCore` logic + `CannonballApp` UI) plus
an Xcode shell project in `Shell/`:

1. `cd Shell && xcodegen generate` produces `CannonballShell.xcodeproj`
   (thin `@main` wrapper over `CannonballScene`, local package dependency,
   Info.plist keys and background modes already configured).
2. Copy `Shell/Secrets.example.plist` to `Shell/Secrets.plist` (gitignored,
   never commit) and fill in `TessieVIN` and `TessieToken`.
3. Build/run the `CannonballShell` scheme on a simulator or device. Remaining
   capability work: request the Critical Alerts entitlement from Apple early
   (docs §2.6).
4. `swift test` runs the core suites (charge curve, SOC targets, trip planner)
   on any Mac — no simulator needed.

Pre-run data tasks (Phase 0, docs §5.1): regenerate `CorridorSeed` from
supercharge.info + a real routing pass (every seed row ships `verified: false`
and the app must not run the real event on unverified rows), bake the corridor
elevation profile into `CorridorModel`, and run the day-0 CAN probe +
capacity-calibration charge.

## Status

Complete core implementation + app shell: fusion, charge-curve model with
residual learning, corridor DP planner, watchdog, Nav challenger, weather,
preconditioning, and all three screens. Remaining before the run: Xcode shell
project, Phase-0 bench verification (Panda framing, CAN IDs), corridor data
bake, and device testing. See `docs/05-implementation-plan-and-edge-cases.md`.
