# 1 · Battery Specification & Charge-Curve Model — 2025 Model 3 RWD (US)

## 1.1 Which pack this car actually has (and why it matters)

The single most important research finding for this project: **the 2025
US-built (Fremont) Model 3 RWD does not use the CATL LFP pack** that base RWD
Model 3s use in China/Europe and that pre-Highland US RWDs (2021–2023) used.
Tariff and import restrictions on Chinese-made LFP packs pushed Tesla to fit
US RWD cars with a **software-range-locked nickel-based (Panasonic 2170
NCA/NMC-family) pack** — physically the Long Range pack hardware, capacity- and
power-limited in firmware.

Spec sheets on aggregator sites (EV Database "CATL LFP60" / "CATL 6M" entries)
describe the **export-market** car. Do not use them for this vehicle. Equally,
do not use unlocked Long Range numbers (78 kWh usable / 250 kW peak): the lock
changes both capacity and the power-vs-*indicated*-SOC curve.

### Hard-coded pack profile (`PackProfile.us2025RWDNickel`)

| Parameter | Value | Confidence / source of truth |
|---|---|---|
| Chemistry | Nickel-based (Panasonic 2170, NCA/NCMA family) | High — locked pack, US sourcing |
| Gross hardware capacity | ~78–79 kWh (LR pack hardware) | High |
| **Usable (locked) capacity** | **62.4 kWh** | Medium-high (owner OBD/BMS reads; TMC "new 62.4 kWh battery") — **calibrated live from BMS on day 0, see §1.5** |
| Pack architecture | 96s46p-class, 400 V class | High |
| Nominal voltage | ~346 V (3.6 V/cell × 96s) | High |
| Max voltage (locked full) | ~390–395 V (locked "100%" ≈ ~80% true cell SOC) | Medium |
| Nameplate peak DC power | 170 kW (Tesla spec for RWD trim) | High |
| Peak DC current | ~500 A class at low SOC | Medium |
| AC onboard charger | 11.5 kW (48 A) | High |
| EPA rated range (2025 US RWD) | 272 mi | High |
| Rated consumption | ≈ 229 Wh/mi (62.4 kWh ÷ 272 mi) | Derived |

### LFP fallback profile (`PackProfile.lfp60`)

Kept in code for completeness and because VIN/firmware detection must be
verified against *this* physical car on day 0 (a small number of early-2025 US
RWD builds may carry over CATL LFP60 stock): 60.9 kWh gross / 57.5 kWh usable,
prismatic CATL LFP, ~360 V class, 170 kW peak with a flatter but
earlier-tapering curve, and the classic LFP property that **BMS SOC drifts
badly without periodic 100% charges** (flat OCV curve). The app selects the
profile at startup from BMS pack-voltage-at-SOC signature (LFP ≈ 3.2 V/cell
nominal vs ~3.6 V/cell nickel — unambiguous from CAN pack voltage ÷ 96).

### Why the locked nickel pack is a strategic gift for a cannonball

Displayed SOC is rescaled over the locked window. Indicated 100% ≈ ~80% true
cell SOC, indicated 0% ≈ ~0–3% true. Consequences the optimizer exploits:

1. **The taper vs indicated SOC is gentler than an unlocked car's.** The cell
   is at lower true SOC than the display suggests, so high power holds deeper
   into the indicated range.
2. **Charging to indicated 100% is not the disaster it is on an unlocked NCA
   pack** — the terminal taper still slows things, but there is no 80→100%
   "half-hour for 20%" cliff. Legs can therefore be planned with higher
   departure SOC when stop spacing demands it.
3. **Low-end buffer**: arriving at indicated 2–3% is less risky than on LFP
   (accurate SOC estimation on nickel chemistry, real bottom buffer), which
   lets the safety buffer be tighter — minutes saved at every stop.

## 1.2 Base charge curve (25 °C cell, unshared V3/V4 stall)

Priors, encoded as a monotone-interpolated table of **indicated SOC → kW**.
These are *starting* values, blended with live-observed residuals (§1.5).

| Ind. SOC % | 0 | 5 | 10 | 15 | 20 | 25 | 30 | 40 | 50 | 60 | 70 | 80 | 90 | 97 | 100 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| kW | 120 | 165 | 170 | 170 | 170 | 168 | 162 | 148 | 130 | 110 | 90 | 68 | 48 | 28 | 8 |

Notes:
- 0–5% ramp reflects handshake + current ramp, not a battery limit.
- The 10–25% plateau at the 170 kW firmware cap is the money zone: **arrive
  low**. Average power 10→60% ≈ 145 kW; 10→80% ≈ 130 kW-class.
- The taper is roughly linear from ~30% — characteristic Tesla nickel behavior,
  stretched rightward by the SOC rescaling of the lock.
- Time-to-SOC integration uses `dt = capacity × dSOC / P(SOC)` on a 0.5% grid.

## 1.3 Temperature modifier

Charge power = `min(vehicleCurve(SOC) × f_temp(T_cell), siteCap, bmsRequestKW)`.

`f_temp` on **max cell temp** for hot limits and **min cell temp** for cold
limits (the BMS limits on the worst cell; S3XY gives us both):

| Min cell °C | ≤ −10 | 0 | 10 | 20 | 25–45 | — |
|---|---|---|---|---|---|---|
| Cold factor | 0.15 | 0.35 | 0.65 | 0.90 | 1.00 | |

| Max cell °C | ≤ 45 | 50 | 55 | 60 | |
|---|---|---|---|---|---|
| Hot factor | 1.00 | 0.85 | 0.60 | 0.40 | |

- Ideal arrival window: **≈ 40–50 °C max cell** for peak acceptance at low SOC.
- Preconditioning target: the app times precondition-start so predicted
  arrival cell temp lands in that window (model: pack heats ~0.5–0.8 °C/min
  while preconditioning at highway speed, less in extreme cold; learned live).
- Back-to-back fast legs in desert heat (I-15/I-10 in summer) flip the
  problem: the hot factor bites, and the app recommends *against*
  preconditioning and may prefer slightly longer, cooler charge stops.

## 1.4 Supercharger version modifier (site cap)

| Version | Cabinet cap per car | Sharing behavior |
|---|---|---|
| V2 (150 kW) | 150 kW | **Paired stalls (1A/1B)** split a cabinet; a neighbor can halve you. Watchdog + stall-choice logic critical. |
| V2 urban | 72 kW | Never acceptable on this run except emergencies. |
| V3 | 250 kW | No pairing; site-level power can still sag at full occupancy. |
| V4 stall / V3 cabinet | 250 kW | As V3; longer cables (irrelevant here). |
| True V4 cabinet | 325+ kW | No benefit to this car (170 kW vehicle cap) but implies healthy site power budget. |

For this car the vehicle cap (170 kW) binds at V3+; **V2 sites still deliver
~148–150 kW**, so a perfectly-placed V2 is only ~8–12% slower at low SOC and
can beat a V3 with a longer detour — the scorer treats version as an input to
expected power, never as a hard filter. Stall-pairing metadata is used at V2
sites to recommend an unpaired stall on arrival.

## 1.5 Live calibration & residual learning

1. **Day-0 capacity calibration**: from CAN, integrate `V × I` over a
   20→80% charge and scale against ΔSOC to correct usable-kWh (also
   cross-checked against Tessie's reported added kWh).
2. **Curve residuals**: during every DC session, store `(SOC, T_cell,
   siteVersion, expectedKW, actualKW)` samples. An exponentially-weighted
   residual spline (keyed by SOC decile) adjusts the prior curve for *this*
   car — degradation, firmware changes, and lock behavior all wash into it.
3. **Watchdog separation of concerns**: residual learning updates only from
   sessions judged "healthy" (no sharing suspected, thermal factor ≈ 1);
   otherwise a bad stall would teach the model to expect bad stalls.

## 1.6 Practical planning constants for the run

- Planning SOC window: **arrive 8–12%, depart 55–65%** for most legs
  (average charge power maximized); depart higher only when stop spacing
  (e.g., Green River → Vegas gaps on I-70/I-15) demands it.
- Buffer policy: dynamic (see decision-engine doc §3.3), floor at 6% indicated
  arrival under worst-case headwind forecast error.
- ~14–16 stops expected over ~2,790 mi at FSD highway speeds; total charge time
  is the dominant controllable variable (~4.5–6 h), which is why per-stop
  optimization is the app's core mission.
