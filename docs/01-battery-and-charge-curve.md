# 1 · Battery Specification & Charge-Curve Model — 2025 Model 3 Premium RWD (US)

## 1.1 The exact pack in this car

Target vehicle: **2025 Tesla Model 3 Premium RWD** (US variant — the
higher-trim single-motor RWD formerly badged Long Range RWD, from ~$42,490,
**363 mi EPA**). Its pack:

- **Chemistry**: nickel-cobalt-aluminum (NCA) lithium-ion, cylindrical
  **Panasonic 2170** cells, US-built pack.
- **Usable capacity: 79 kWh** (~82 kWh nominal/gross).
- **Peak DC fast charge: 250 kW** (vehicle-limited; V3/V4 sites deliver it).
- AC onboard charging ≈ 11.5 kW (irrelevant to the run).

Two traps this spec explicitly avoids:

1. **Base "Standard/RWD" numbers do not apply.** The $36k-class RWD trims use
   smaller packs (imported CATL LFP in most markets; capacity-limited packs in
   some US builds) with a 170 kW cap. Aggregator entries like EV Database's
   "CATL LFP60"/"CATL 6M" describe those cars, not this one.
2. **LFP planning heuristics do not apply.** No flat-OCV SOC drift, no
   charge-to-100%-periodically requirement, and a very different power curve.

### Hard-coded pack profile (`PackProfile.us2025PremiumRWD`)

| Parameter | Value | Confidence / source of truth |
|---|---|---|
| Chemistry | NCA (Panasonic 2170, cylindrical) | High |
| Gross capacity | ~82 kWh | High |
| **Usable capacity** | **79 kWh** | High — still **calibrated live from BMS on day 0, §1.5** (real-world packs read 77–79 depending on build/degradation) |
| Pack architecture | 96s, 400 V class, 4416 cells | High |
| Nominal voltage | ~346 V (3.6 V/cell × 96s); ~403 V at full | High |
| Nameplate peak DC power | 250 kW | High |
| Peak DC current | ~630 A class at low SOC on V3 | Medium |
| EPA rated range | 363 mi | High |
| Rated consumption | ≈ 218 Wh/mi (79 kWh ÷ 363 mi) | Derived |

### LFP fallback profile (`PackProfile.lfp60`)

Retained in code purely as a safety net: the app verifies chemistry on day 0
from the CAN pack-voltage-at-SOC signature (NCA ≈ 3.5–3.7 V/cell mid-SOC vs
LFP pinned near 3.3 V — unambiguous from pack voltage ÷ 96). If a fleet swap
or spec surprise ever puts an LFP car under this app, the planner flips
profiles (57.5 kWh usable, 170 kW peak, flatter-earlier taper, bigger SOC
floor for BMS drift) without code changes.

## 1.2 Base charge curve (25 °C cell, unshared V3/V4 stall)

Priors, encoded as a monotone-interpolated table of **SOC → kW**, blended with
live-observed residuals (§1.5). This is the classic aggressive Tesla NCA
taper: a short, tall peak and a long slide.

| SOC % | 0 | 5 | 10 | 15 | 20 | 25 | 30 | 40 | 50 | 60 | 70 | 80 | 90 | 97 | 100 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| kW | 130 | 240 | 250 | 235 | 200 | 180 | 160 | 132 | 108 | 90 | 74 | 58 | 38 | 22 | 5 |

Consequences the optimizer is built around:

- **The 250 kW peak is brief (~5–15%) — arriving low is worth real minutes.**
  Every % of SOC you arrive with above ~10% is energy you bought at 60–130 kW
  that you could have bought at 200–250 kW.
- Average power 10→50% ≈ 175 kW; 10→60% ≈ 160 kW; 10→80% ≈ 125 kW
  (10→80% ≈ 27–28 min for 55.3 kWh). **Above ~60% the marginal minute buys
  less than half what it buys at 15%** — the dynamic SOC target (§3.3) exists
  to exploit exactly this.
- Charging past ~80% is almost never optimal on this run; past 90% only when
  a single long gap demands it (the DP decides, not a rule of thumb).
- Time-to-SOC integration uses `dt = capacity × dSOC / P(SOC)` on a 0.5% grid.

## 1.3 Temperature modifier

Charge power = `min(vehicleCurve(SOC) × f_temp(T_cell), siteCap, bmsRequestKW)`.

`f_temp` uses **min cell temp** for cold limits and **max cell temp** for hot
limits (the BMS limits on the worst cell; S3XY gives us both):

| Min cell °C | ≤ −10 | 0 | 10 | 20 | 25–45 | — |
|---|---|---|---|---|---|---|
| Cold factor | 0.15 | 0.35 | 0.65 | 0.90 | 1.00 | |

| Max cell °C | ≤ 45 | 50 | 55 | 60 | |
|---|---|---|---|---|---|
| Hot factor | 1.00 | 0.85 | 0.60 | 0.40 | |

- Ideal arrival window: **≈ 40–50 °C max cell** for full 250 kW acceptance at
  low SOC — a cold-soaked pack takes a >2× time penalty on the peak zone, so
  preconditioning matters *more* on this pack than on a 170 kW-capped one.
- Preconditioning target: the app times precondition-start so predicted
  arrival cell temp lands in that window (pack heats ~0.5–0.8 °C/min while
  preconditioning at highway speed; learned live).
- Desert heat flips it: repeated 250 kW sessions push cells toward the hot
  taper; the planner spaces high-power stops and the watchdog distinguishes
  THERMAL (stay) from BAD STALL (move).

## 1.4 Supercharger version modifier (site cap)

| Version | Cabinet cap per car | Sharing behavior |
|---|---|---|
| V2 (150 kW) | 150 kW | **Paired stalls (1A/1B)** split a cabinet; a neighbor can halve you. |
| V2 urban | 72 kW | Never acceptable on this run except emergencies. |
| V3 | 250 kW | No pairing; site power can still sag at full occupancy. |
| V4 stall / V3 cabinet | 250 kW | As V3; longer cables (irrelevant here). |
| True V4 cabinet | 325+ kW | No headroom benefit (car caps at 250 kW) but implies a healthy site power budget. |

Unlike a 170 kW-capped car, **this pack leaves ~100 kW on the table at V2
sites in the peak zone** — the scorer's expected-power model makes V2 sites
genuinely expensive below ~40% SOC, so a modest extra detour to a V3 usually
wins. Above ~55% SOC the curve is under 100 kW anyway and V2 stops become
competitive again; the DP finds these crossovers, never a version filter.
Stall-pairing metadata still drives unpaired-stall recommendations when a V2
is chosen.

## 1.5 Live calibration & residual learning

1. **Day-0 capacity calibration**: from CAN, integrate `V × I` over a 20→80%
   charge and scale against ΔSOC to correct usable-kWh (cross-checked against
   Tessie's reported added kWh and `BMS_energyStatus` full-pack value).
2. **Curve residuals**: during every DC session, store `(SOC, T_cell,
   siteVersion, expectedKW, actualKW)` samples. An exponentially-weighted
   residual spline (keyed by SOC decile) adjusts the prior curve for *this*
   car — degradation, firmware changes, and battery-day variance wash into it.
3. **Watchdog separation of concerns**: residual learning updates only from
   sessions judged "healthy" (no sharing suspected, thermal factor ≈ 1);
   otherwise a bad stall would teach the model to expect bad stalls.

## 1.6 Practical planning constants for the run

- Planning SOC window: **arrive 5–10%, depart 45–60%** for most legs — the
  aggressive taper makes many short charges strictly faster than few long
  ones, within stall-overhead limits (~45 s handshake + off/on-ramp time
  bounds how short a stop can profitably be).
- Buffer policy: dynamic (decision-engine doc §3.3), floor at 5% arrival
  under worst-case headwind forecast error (NCA SOC estimation is accurate;
  no LFP-style drift margin needed).
- ~9–11 stops expected over ~2,790 mi at FSD highway speeds; total charge
  time ≈ 3.5–4.5 h and is the dominant controllable variable — which is why
  per-stop optimization is the app's core mission.
- 363 mi rated range means theoretical 300+ mi legs exist, but the DP will
  rarely choose them: driving deep into the buffer then charging through the
  taper loses to an extra short stop in the peak zone almost everywhere the
  corridor offers dense site spacing (I-80/I-70 gaps in WY/UT are the
  exceptions the DP handles explicitly).
