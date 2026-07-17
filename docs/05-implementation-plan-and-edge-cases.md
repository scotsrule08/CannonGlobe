# 5 · Implementation Plan & Edge Cases

## 5.1 Phased plan

### Phase 0 — Bench & calibration (1 week, before any UI polish)
- PandaClient probe against the real Commander: confirm ports, framing, and
  live decode of the eight core signals. **Go/no-go gate**: if Wi-Fi CAN is
  flaky, the whole fusion layer degrades to Tessie-primary and thresholds
  loosen — decide early.
- Day-0 capacity calibration charge (20→80%) + pack-chemistry signature check
  (§1.1) — confirms the 62.4 kWh nickel profile numbers on the actual car.
- Record two highway calibration drives (100+ mi) to seed the efficiency
  learner.

### Phase 1 — Run-ready MVP (the actual cannonball needs exactly this)
1. Fusion engine with CAN + Tessie + GPS, source badges, offline store.
2. Charge curve model + **charge watchdog + charge screen** (biggest single
   time-saver: catching one shared V2 stall pays for the app).
3. Dynamic SOC target + depart-now alert (second biggest: eliminates
   over-charging at every one of ~15 stops).
4. Corridor DP with bundled SC snapshot + live occupancy; Compare screen with
   Tesla-Nav delta; voice + notifications.
5. Precondition timing prompts via Fleet nav-share.
- Cut line: stall-level pairing maps only for V2 sites actually on the plan;
  ABRP, occupancy priors backend, and background-mode hardening are *not* MVP
  (phone is mounted and powered).

### Phase 2 — Hardening (post-shakedown drive)
- Occupancy prior collection worker; wind-forecast error tracking; thermal
  model fit from Phase-0/1 logs; Critical Alerts entitlement (apply week 1 —
  Apple lead time); full offline drills (airplane-mode test through a
  simulated leg); watchdog false-positive tuning.

### Phase 3 — Full vision
- Multi-day/multi-driver support, run replay & analytics, ABRP cross-check,
  automatic stall recommendation from pairing map + occupancy at V2 sites,
  Shortcuts/CarPlay surface, shareable live run page.

## 5.2 Edge-case handling

| Scenario | Behavior |
|---|---|
| **Cold snap (Rockies at night)** | Cold factor crushes charge acceptance: planner pre-shifts to earlier precondition starts, longer legs between stops (driving keeps pack warm beats short cold charges), buffer floor +2%. |
| **Desert heat (Mojave leg)** | Hot factor + back-to-back fast charging: planner spaces high-power stops, may prefer 2 shorter charges over 1 long thermally-limited one; watchdog labels THERMAL (stay) vs BAD STALL (move) so we don't stall-hop uselessly on a hot pack. |
| **High head/cross winds (Kansas/Oklahoma panhandle winds)** | Wind is a first-class model input; forecast refresh hourly; live residual (actual vs predicted Wh/mi) detects unforecast wind within ~10 mi and re-plans — the classic cannonball failure (arriving 4% under plan) becomes a slow-down advisory 40 mi early instead of a crisis. |
| **Crowded Supercharger** | Occupancy → expected queue + shared-power estimate in the score; if a site flips crowded mid-leg, re-score fires a better-site-ahead alert with the minute delta. |
| **FSD disengagement / manual driving stint** | CAN flags the segment; efficiency learner quarantines it; if manual driving is systematically faster/less efficient, a separate profile forms and the active profile follows current mode. |
| **S3XY Wi-Fi drops** | Per-signal failover (§2.3) within seconds; watchdog thresholds widen; voice announces "CAN lost, cloud mode" once, UI badge persists. Reconnect is automatic via heartbeat. |
| **Tessie rate-limited / Tesla API outage** | REST governor + cached state; streaming unaffected path kept separate; total-cloud-loss = full offline mode (bundled data), which is exercised in Phase-2 drills, not discovered in Utah. |
| **Site offline / stalls dead on arrival** | supercharge.info status + `nearby_charging_sites` delta on approach; every plan keeps a reachable fallback site within remaining-range at the buffer floor — the DP forbids legs whose failure strands the car. |
| **BMS SOC drift** | Nickel pack: minimal; coulomb-counting cross-check flags >2% divergence. If the car turns out LFP (§1.1): planner schedules one 100% charge overnight pre-run and trusts energy (kWh) over SOC % mid-run. |
| **Phone thermal throttling on the dash** | 1 Hz UI, no map rendering on the drive screen by default, brightness advisory; all heavy compute is event-driven. |
| **Charge-port/handshake failure, single retry rule** | If session power ≤ 5 kW 90 s after plug-in → immediate re-plug advisory; second failure → adjacent stall; third → site-hop score with realized zero energy. |

## 5.3 Success metrics (post-run scorecard)

- Σ (actual charge minutes − ideal-curve minutes) < 8 min over the run.
- Zero arrivals below buffer floor; zero charges past target +2%.
- Watchdog: ≥ 1 caught underperforming stall (expected statistically), no
  false SEVERE alerts.
- Plan-vs-actual leg energy error ≤ 3% after the first 150 mi.
