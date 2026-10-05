# Journal, insights, and the features around them

This document is for the features that came after the core dashboard: the journal,
the insights, workouts from other sources, export and restore, and the iOS-only
parts (notifications, widgets, Siri, live heart rate, the ring page).

The rule of `clients-web-and-ios.md` applies: the shared brain (`oura-summary`)
computes, the clients show. The algorithms are in `oura-analysis::insights` of
open_oura; see `docs/algorithms/insights.md` there.

## Files next to the database

| file | writer | content |
| --- | --- | --- |
| `oura.db` | the sync | raw ring events, readings, the `daily_summary` cache |
| `profile.json` | the client | age, sex, height, weight, ring size, activity goal |
| `feature_modes.json` | the client | the last known mode of each ring feature |
| `journal.json` | `oura_summary::journal::apply` | tags, manual workouts, period days, rest mode |
| `external.json` | the client | workouts and measured VO2 max from Apple Health |

The ring knows nothing about the journal and the external data. The hub keeps a
copy of the ring rows only, so a restore from the hub does not restore them.

## The journal

Every change is one JSON operation. The iOS app sends it through the FFI
(`journalApply`), the desktop through `oura journal '<json>'`.

| `op` | fields |
| --- | --- |
| `add_tag` | `day`, `tag`, `note` (optional) |
| `remove_tag` | `id` |
| `add_workout` | `start_unix`, `duration_min`, `label`, `active_kcal` and `note` (optional) |
| `remove_workout` | `id` |
| `add_period`, `remove_period` | `day` (the first day of the period) |
| `set_rest_mode` | `on`, `day` |

A tag belongs to a local day (`YYYY-MM-DD`). The same tag on the same day is
stored one time.

## New keys of the summary JSON

| key | content |
| --- | --- |
| `nights[].breath`, `.temp_dev`, `.kind`, `.deep_min`, `.light_min`, `.rem_min`, `.awake_min` | breathing rate, temperature deviation, `main` or `nap`, stage minutes |
| `vitals.breath`, `vitals.spo2`, `vitals.temp_dev` | series, latest, baseline and `delta` of the main sleeps |
| `device.battery` | `latest`, `history` (14 days), `charging`, `rate_pct_per_day`, `days_left` |
| `workouts[]` | one list from the ring, Apple Health and the journal, with `source` |
| `stress` | daytime stress zones for 14 days, and a 48-hour timeline |
| `resilience` | score, level and the three parts |
| `guidance` | `bedtime` window and `regularity` (SRI, clock spread, chronotype) |
| `illness` | the model's result, or the rule-based check (`basis: "rules"`) |
| `reports` | `weeks` and `months` with averages, totals and `highlights` |
| `correlations` | for each tag, the night after it against the other nights |
| `cycle` | cycle day, phase, next period (null without a logged period) |
| `journal`, `rest_mode` | the journal, and the days in rest mode |
| `fitness.source` | `measured` (Apple Health) or `formula` |

### Rules that are in the summary, not in a client

- **Main sleep and nap.** The longest sleep of a wake day with 3 hours or more is the
  main sleep. All other sleep periods are naps. Vitals with decimals use main sleeps
  only.
- **Workouts.** A ring session that overlaps an entry from Apple Health or the
  journal by half or more is dropped. When an entry reports more active energy than
  the ring measured in its time, the day gets the difference. Thus a workout with
  the ring on the finger does not count two times.
- **Rest mode.** A day in rest mode has no Activity score. The readiness score of
  that day does not use the activity contributors.
- **Ring sessions without the model.** A build without the activity model gets
  sessions from the MET minutes: 15 minutes or more at 3 MET or more. The ring cannot
  tell the type of the activity, so the label is `Moderate activity` or
  `Vigorous activity`.
- **Correlations.** A tag needs 3 nights. A result shows only when the effect size
  and Welch's t are large enough (`clear`: d ≥ 0.5 and t ≥ 2.5; `weak`: d ≥ 0.2 and
  t ≥ 1.5).

## Export and restore

- `oura export --format csv|json` and the iOS Settings → Export give the same files.
  The CSV has one row per local day with every metric (`extras::METRICS`).
- Restore (iOS Settings → Restore) reads `GET /export/events` of the hub page by
  page and imports each page with `import_batch`. Rows that are in the database
  already are skipped.
- `oura_store::replication::BATCH_VERSION` is the version of a page. It changes only
  when the rows change shape, so a hub with an older store accepts the pages of a
  newer phone.

## Demo data

`oura --db demo.db demo-db demo.db --days 45` writes a database with a complete
history, a journal and Apple Health workouts. The iOS app offers the same data in
Settings when no ring is paired and no database exists. The demo events carry the
decoded JSON of the real decoders, but their bodies are counters: do not run
`redecode` on a demo database.

## iOS only

### Notifications (`Notifier.swift`)

The app has no server. It decides each notification on the phone.

| notification | when |
| --- | --- |
| Ring battery is low | at the sync that reads 20 % or less, one time per discharge |
| Ring battery is probably low | at the estimated time of 20 %, from the discharge rate |
| No sync for a day | 24 hours after the last sync (scheduled again at each sync) |
| Morning scores are ready | at the first summary of the day that has a readiness score |
| Symptom Radar changes | when the status of the check changes |
| Bedtime reminder | each day, 30 minutes before the ideal bedtime window |

`NotificationRules.plan` has no side effects. The tests call it with a summary and a
state.

### Widgets and Siri (`OuraWidgets/`, `Snapshot.swift`, `AppIntents.swift`)

After each summary, the app writes `snapshot.json` to the App Group container and
asks WidgetKit to draw again. The widgets and the three app intents (readiness,
sleep score, ring battery) read that file. A widget cannot talk to the ring.

The App Group id follows the bundle id: `group.$(APP_BUNDLE_ID)`. A build for
another team overrides **`APP_BUNDLE_ID`** on the `xcodebuild` line. Do not override
`PRODUCT_BUNDLE_IDENTIFIER`: that gives the app and the widget extension the same
bundle id, and the install fails.

### Live heart rate (`LiveHeart.swift`)

`SyncCoordinator.withRing` connects to the ring for something that is not a sync.
`RingSession.liveHeartRate` streams one frame per beat until the app calls
`cancel`, then it sets the ring back to automatic measurement. A link that drops
during the stream starts the stream again (3 attempts). When the ring gives no
beat, the app shows the last stored reading of the ring (`latestReading`).

The simulator has no Bluetooth. There the session uses made-up beats, and the
screen says so.

### The ring page (`RingScreen.swift`)

- Battery history and the days left come from `device.battery`.
- The feature switches call `RingSession.setFeature`. A Gen3 ring can drop the link
  about 2 seconds after it accepts a change. The change is kept.
- The finder shows the strength of the ring's Bluetooth signal. No command is known
  that makes the ring blink or vibrate.

## Not possible from an independent client

| item | cause |
| --- | --- |
| Firmware update | the update files come from Oura's servers and need an account token |
| Profile on the ring (`0x20`) | only the empty-value frames are known, not the value format |
| Step counts from `0x51`/`0x52` | the official parser has no layout for these events |
| Oura's stress, resilience and cycle models | cloud scores or models that depend on them; the app has estimates |
| Vascular age without the model | needs the CVA model (torch build) |
