# 4 · Data Integrations & Legal

## 4.1 Enhance Auto S3XY Commander (primary live source)

**Transport.** Commander joins/creates Wi-Fi; Panda-compatible endpoint at
`192.168.4.1`. Panda protocol specifics (comma.ai lineage):
- **UDP 1338**: send periodic "hello" heartbeat (any datagram, ≥1/5 s) →
  device streams CAN frames back to the sender's addr:port. Frame wire format:
  repeated 16-byte records `[addr:u32 | busTime:u32 | dlc+flags:u32 | data:8B]`
  (classic Panda USB bulk format encapsulated in UDP).
- **TCP 1337** on some firmwares for reliable control-channel commands.
- Must be verified against the actual Commander firmware on day 0 — the
  `PandaClient` has a probe mode that logs raw frames and auto-detects record
  framing. Budget a bench day for this; it is the highest-risk integration.

**Signals (Model 3 DBC — IDs from the community `Model3CAN.dbc`).**

| Signal | CAN msg (typ.) | Use |
|---|---|---|
| Pack voltage/current | `ID132 HVBattAmpVolt` (0x132) | true power, capacity calibration |
| SOC (UI + min/max) | `ID33A UI_SOC` / `ID352 BMS_energyStatus` | fusion SOC + usable kWh remaining |
| Cell temps min/max | `ID312 BMS_thermal` | watchdog, precondition planner |
| BMS max charge/discharge | `ID2D2 BMS_powerLimits` (0x2D2) | expected-power ceiling, THERMAL diagnosis |
| Fast-charge power/state | `ID264 chargeLine` / DI status | actual kW at 1 Hz |
| Ambient/cabin temp | `ID243 VCRIGHT/HVAC` group | HVAC model |
| Speed/odometer | `ID257 DIspeed` | efficiency learner ground truth |
| Precondition/heater state | BMS status bits | closing the loop on precondition triggers |

Exact IDs verified against the DBC bundled in-repo at build time; decode is
table-driven, so day-0 corrections are data edits, not code edits.

**Commands.** Commander's officially supported control path is Enhance's own
app/BLE buttons, not a documented Wi-Fi API. Design: attempt discovery of the
Enhance local API for precondition toggle; if absent, preconditioning falls
back to the Fleet-API nav-share trigger (§3.7). **Never TX arbitrary frames
onto the powertrain bus while FSD is engaged** — RX-only on the Panda link is
a hard rule for this project (safety + warranty).

## 4.2 Tessie (cloud state + history) & Tesla Fleet API

- Tessie REST mirrors Fleet vehicle-data (`GET /{vin}/state?use_cache=true`
  for cheap polls) and adds `/{vin}/battery_health`, drives, charges — used to
  seed the efficiency learner and capacity calibration before the run.
- Tessie streaming (Fleet Telemetry mirrored over WebSocket/SSE) for sub-30 s
  location/SOC/charger_power when off CAN. One token, no OAuth dance, no
  per-vehicle Fleet Telemetry config: this is why Tessie is preferred over
  direct Fleet API for the run. Direct Fleet API is implemented behind the
  same protocol so we can drop Tessie if it rate-limits (documented limits are
  generous; governor caps us at 1 poll/15 s cached regardless).
- Fleet API commands used: `navigation_request` (send SC destination → also
  triggers on-route battery preconditioning — this is the reliable,
  ToS-clean precondition lever), honk/flash (stall identification at night),
  charge limit set (belt-and-suspenders vs in-car 100% setting), and
  `nearby_charging_sites` (**live stall availability** — the semi-public
  occupancy source, mirrored by Tessie).

## 4.3 Supercharger network data

- **Static**: bundled corridor snapshot (id, coords, stalls, version, cap kW,
  detour secs both directions, V2 pairing maps) built pre-run from
  supercharge.info community data + Tesla's public site list, hand-verified
  for the ~40 plausible stops. Offline-first: the run must survive with only
  this.
- **Live occupancy**: Fleet/Tessie `nearby_charging_sites` (available_stalls /
  total_stalls) polled for sites within 150 mi ahead, 60–120 s cadence.
- **Statistical fallback**: hour-of-day × day-of-week occupancy priors per
  site (seeded from a 2-week pre-run polling script — the one optional
  backend component), blended with live data by freshness.

## 4.4 ABRP (optional cross-check)

- Planning API requires a partner/app key (apply via Iternio; document key in
  `Secrets.xcconfig`, never committed). Telemetry API accepts a user token
  from the ABRP app ("Live data" → generic token) — we can push our fused
  telemetry so ABRP's plan reflects real SOC.
- Role: independent sanity check of the DP plan, surfaced only when the two
  disagree by > 10 min (guards against our own model bugs mid-run). Graceful
  absence: feature-flagged off when no key.

## 4.5 Maps, elevation, weather

- MapKit directions with `requestsAlternateRoutes = true`, traffic ETAs; ETA
  refresh 5 min rolling for current + next leg, hourly beyond.
- Elevation: corridor profile pre-baked into the offline store (100 m
  sampling, ~2,800 mi ≈ 45k points ≈ trivial); no live dependency.
- Weather: Open-Meteo hourly (free, keyless): 10 m wind speed/direction/gusts,
  temp, precip along-route at 25-mi spacing, refreshed hourly; decomposed to
  head/cross wind per leg bearing. NWS as fallback. Wind is the #1 forecast
  input to buffer sizing — both are cached with staleness tags.

## 4.6 Legal / ToS considerations (not legal advice)

- **CAN via S3XY**: reading CAN through Enhance's own shipped Wi-Fi interface
  on your own vehicle is within the accessory's intended use; it does not void
  the Magnuson-Moss warranty by itself, though Tesla can deny warranty on
  damage *caused* by an accessory. RX-only posture keeps risk minimal. No
  Tesla ToS governs the CAN bus itself.
- **Tesla Fleet API**: requires a registered developer app; personal use tier
  is fine. ToS prohibits vehicle-command abuse and high-frequency polling —
  our command usage (nav share, charge limit) is squarely normal. Fleet
  Telemetry config pushes require a virtual key — Tessie handles this.
- **Tessie**: paid subscription per ToS; API use for the owner's own vehicle
  is the product's purpose. Respect rate limits (the governor enforces).
- **ABRP**: Planning API commercial use needs an agreement with Iternio;
  single-user personal use with a granted key is their documented path.
- **supercharge.info** data: community DB, attribution required; we bundle a
  static snapshot for personal use with attribution in-app.
- **Occupancy**: only via official `nearby_charging_sites` — no scraping of
  the in-car UI or private endpoints.
- **The elephant**: a "cannonball run" implies sustained speeds that may
  exceed posted limits; FSD itself enforces limits + offsets. The app only
  optimizes charging/routing and never advises speeds above the FSD-attainable
  legal envelope; traffic-law compliance is the driver's responsibility. Also
  note: FSD (Supervised) requires a fully attentive driver at all times —
  the app's alerts are designed for glance/voice specifically so they never
  compete with supervision duties.
