# Daily summaries, baselines & live Readiness

To compute the **baseline-relative** score contributors (HRV Balance, Resting-HR,
Sleep/Activity Balance), an independent client must carry the same per-day state
`ecore` accumulates on-device: a daily summary plus rolling personal baselines.
This is the substrate that turns Readiness/Activity from "weights-solved" (see
[`score-weights.md`](score-weights.md)) into *live from the ring*.

## Where the missing inputs come from

Almost nothing extra is needed from the ring — we already capture the raw signals.
The gap was **accumulated local state**, plus one app/account setting:

| Contributor input | Source | How it's produced now |
| --- | --- | --- |
| HRV (nocturnal) | Ring `hrv_event` 0x5d | mean nocturnal RMSSD |
| Resting HR | Ring IBI 0x60 | overnight HR → low/avg |
| **Recovery Index** | Ring IBI 0x60 | hours between RHR minimum and wake (single night) |
| Skin temperature | Ring `temp_event` 0x46 | mean nocturnal temp − trailing baseline |
| Activity MET | Ring `activity_information` | mean MET over the day |
| HRV/RHR/temp/sleep/MET **baselines** | **local state** | trailing-14-day mean, accrued nightly |
| Activity goal (Meet Daily Targets) | **app/account** (`DbDailyActivity.target_calories`, adaptive) | not reproduced — Activity stays goal-gated |

## Where it runs now

`oura-summary` computes the per-day values and the scores when it builds the summary
(`oura-analysis::scores`). It writes the per-day values to the `daily_summary` table in
`oura.db` (`extras::daily_rows`). No separate script is necessary.

`tools/calibrate_scores.py` fits the combiner weights and the contributor curves from a
trends export and writes `local/score_params.json` (gitignored: personal calibration).
It is an analysis tool. The summary does not read that file.

### Recovery Index (single-night)

From the overnight HR series (IBI → bpm, rolling-median smoothed) we find when resting
HR bottoms out and report **hours between that minimum and wake**: Oura's Recovery
Index (the earlier RHR settles, the more recovered). No history is necessary.

## Maturity: baselines need ~14 days

The baseline-relative contributors compare today to a personal ~14-day baseline. With
fewer days the baseline is **cold** (falls back to the current value → neutral
deviation) and the Readiness number is **provisional** — the scorer flags each cold
contributor. After ~2 weeks of nightly sync they mature and Readiness becomes as live
as Sleep.

## What's still gated

- **Activity Score** — `Meet Daily Targets` tracks an adaptive personal goal in
  `DbDailyActivity.target_calories` (app/account, not on the ring); `Training
  Volume/Frequency` are multi-day training load. So Activity stays weights-solved but
  not live-scored. To unblock: read/replicate the goal (age-based default in
  `DbDailyActivityReference`) or expose it as a config value.
- **Recovery Index sub-score curve** — needs a raw-recovery↔sub-score pairing the
  trends export doesn't provide; we surface the raw hours and use a constant sub-score.
