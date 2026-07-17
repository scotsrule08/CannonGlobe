# 3 · Decision Engine

The engine answers one question continuously: **what single action, taken now,
minimizes predicted door-to-door arrival time?** Everything below is a
component of that objective.

## 3.1 Consumption / energy model

Per 100 m route segment `i` with grade `g`, forecast wind vector `w`, speed `v`
(traffic- and FSD-profile-adjusted):

```
P_i = [ ½·ρ(T,alt)·Cd·A·(v + w_head)²·v      // aero, headwind-corrected
      + m·g₉.₈·Crr(T)·v                       // rolling (Crr rises when cold)
      + m·g₉.₈·grade·v ]                      // potential energy (η_regen=0.65
                                              //   credit on descents, capped by
                                              //   regen power limit at high SOC/cold)
      / η_drive(v)                            // ~0.92 highway
      + P_hvac(T_ambient, T_cabin_set)        // 0.3–4 kW
      + P_base                                // ~0.35 kW electronics
E_leg = Σ P_i·dt_i, with σ_leg from wind-forecast error + model residual σ
```

Constants seeded for the 2025 Premium RWD Highland (Cd 0.219, A 2.2 m², m
1780 kg + payload, Crr 0.009 @20 °C) then **overridden by the EfficiencyLearner** (§3.6),
which is what makes the model *this car on FSD*, not a spec sheet.

## 3.2 Trip-plan optimizer (corridor DP)

Offline-prepped: the ~120 Superchargers within 30 min of the I-78/76/70/15/10
corridor form a DAG (edges = drivable legs where arrival SOC ≥ floor).

```
minimize  Σ drive(e) + Σ chargeTime(stop, socIn → socOut) + Σ detour(stop)
state     (stop, socOut bucketed at 2%)
value     DP over topological order; chargeTime from ChargeCurveModel with
          forecast cell temp at arrival (thermal sim along the leg)
```

Re-run (< 100 ms on-device for the remaining corridor) whenever: SOC error vs
plan > 1.5%, wind forecast refresh, occupancy update, watchdog event, or Tesla
Nav changes its intent. Output = `optimizedPlan`; the same DP evaluated with
the car's chosen next stop pinned = `teslaNavPlan` → the Compare delta.

## 3.3 Dynamic SOC target (never "80%")

```
socTarget(stop s, next stop n):
  E_needed   = E_leg(s→n) + E_reserve
  E_reserve  = max( 6% · usable,                       // hard floor
                    z·σ_leg + headwindShock(n) )       // z = 1.3 (~90th pct)
  socArrive* = 8–12% band chosen by DP (arrive-low beats depart-high
               because dP/dSOC < 0 everywhere above the plateau)
  socTarget  = clamp(E_needed/usable + socFloor(n), min 15%, max 100%)
  — but the DP may *raise* it above the greedy value when the marginal
    charge minute now is cheaper than at the next (hotter/slower/V2) stop.
```

Displayed as one number with a live countdown; recomputed every 30 s while
charging so a tailwind materializing mid-charge shortens the stop in real time.

## 3.4 Supercharger scorer — the Tesla Nav challenger

For candidate site `c` vs incumbent `t` (car's choice), radius ≤ 25 min detour:

```
score(c) = detourDrive(c)                        // traffic-aware, both rejoin
         + queueWait(c)                          // occupancy model: live count
                                                 //   if fresh, else historical
                                                 //   p(wait) by site/hour; V2
                                                 //   pairing penalty term
         + chargeTime(c, socArrive(c) → socTarget(c))
         + Δ downstreamCost(c)                   // DP value function at c —
                                                 //   this is what makes it
                                                 //   *jointly* optimal, not
                                                 //   greedy per-stop
recommend switch iff score(t) − score(c) > 90 s  // hysteresis; announce with
                                                 //   the concrete delta
```

`chargeTime` accounts for site version cap, predicted shared-power at
occupancy, and predicted arrival cell temp (a 20-min V2 detour that arrives
with a hot pack in Barstow can genuinely beat a crowded V3 — the model finds
this; gut feel doesn't).

## 3.5 Charge watchdog (per-second, while plugged)

```
expected = curve(soc) · f_temp(cells) · siteCap · bmsLimit
ratio    = actualKW / expected
states:
  HEALTHY        ratio ≥ 0.90
  DEGRADED       0.70–0.90 for >45 s  → diagnose:
      bmsLimit binding & cells hot        → THERMAL (advise: stay, power will
                                            recover as SOC rises; adjust ETA)
      V2 & paired-neighbor occupied       → SHARED  (voice: "Move to stall 4A,
                                            unpaired — saves ~6 min")
      else                                → BAD STALL (advise stall hop if
                                            stallHopCost ~90 s < time lost)
  SEVERE         ratio < 0.70 for >60 s → also re-score nearby sites with
                 actual observed power; if a site-hop wins ≥ 3 min → Critical
                 Alert + voice with the delta
All events logged to ChargeSession; healthy samples feed curve residuals.
```

## 3.6 Efficiency learner

- Segments drives into 5-mi windows tagged (speed, grade class, wind, temp,
  FSD-active). Maintains a recursive least-squares fit of the consumption
  model's free parameters (CdA_eff, Crr_eff, HVAC bias) on the last ~200 mi,
  half-life 60 mi.
- FSD-specific reality: FSD holds set speed with smoother modulation than
  humans but does undertake/lane-dawdle; disengagement events (from CAN) mark
  segments so a human-driven blast doesn't pollute the FSD model.
- Output: `whPerMi(v, grade, wind, temp)` with σ — consumed by §3.1 and the
  buffer math. After ~150 mi of I-78/I-76, leg predictions should be inside
  ±3%.

## 3.7 Preconditioning planner

- Predict cell temp at arrival from current temp, ambient, and leg power
  profile (driving self-heats the pack ~2–4 °C/hr at cruise; precondition adds
  ~0.5–0.8 °C/min).
- Solve for latest start time such that arrival max-cell ∈ [40, 50] °C;
  trigger via: (a) Fleet API navigation share to the SC (car auto-preconditions),
  (b) Commander precondition command if exposed, else (c) voice prompt to the
  driver ("Confirm nav to Effingham on screen — preconditioning should start
  now").
- Hot-side guard: skip/abort preconditioning when predicted arrival temp
  > 45 °C without it (desert afternoons); recommend cabin pre-cool instead
  (shares refrigerant loop capacity).

## 3.8 Recommendation arbitration

One utterance at a time, priority-ordered: SEVERE watchdog > buffer erosion
(arrival SOC forecast < floor → slow-down/divert advice with concrete mph) >
site switch > precondition timing > depart-now (target SOC reached) >
informational. Each has a cooldown and a "state changed" gate so the cabin
isn't a nag machine at 3 a.m. in Kansas.
