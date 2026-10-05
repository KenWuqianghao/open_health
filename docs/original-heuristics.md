# Original heuristics (retired)

open_oura used to ship its own logic under `crates/oura-analysis/src/original/`
for things Oura computes in its cloud. The only such module was
`activity_session` — a threshold-based workout/swim/sauna/cold detector built on
MET, motion, skin temperature and HR.

**It has been removed.** The heuristic classified purely by temperature, so it
mislabeled a morning run as a "Swim" and emitted short "Swim" blips from warm-water
hand contact. The public app now finds workouts from the MET minutes
(`oura-summary`, `extras::met_workouts`). An add-on can supply model sessions through
`OURA_MODEL_RUNNER` (CLI) or a `SummaryPlugin` (iOS).

Everything Oura-derived (faithfully ported from the on-device `ecore` engine,
citing `ecore function @ address`) still lives under
`crates/oura-analysis/src/ported/`.
