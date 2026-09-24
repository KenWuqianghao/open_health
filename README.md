# open_health

[![Open Oura: your Oura ring, no account, no cloud](https://open-oura.vercel.app/assets/og.jpg)](https://open-oura.vercel.app)

The Open Oura iPhone app, and the other local-first health tools around it. The app
pairs an Oura Ring 3, 4, or 5 with a key made on the phone, syncs it over Bluetooth,
computes readiness, sleep, and activity on the phone, and can write to Apple Health
and back up to your own [hub](https://github.com/KenWuqianghao/oura-hub). No Oura
account and no cloud.

## Get started

On a Mac with Xcode, with the iPhone connected by cable:

```bash
git clone https://github.com/KenWuqianghao/open_health.git && cd open_health && ./apps/ios/install.sh
```

Then reset and pair the ring. The full guide, with the ring reset and the hub:
[open-oura.vercel.app/setup](https://open-oura.vercel.app/setup). The iOS details are in
[`apps/ios/README.md`](apps/ios/README.md).

## What lives here

- **`dashboard/web/`**: vanilla HTML/CSS/JS health dashboard served locally.
- **`apps/ios/`**: SwiftUI iOS client and generated Rust FFI bindings.
- **`crates/oura-cli`**: app-oriented CLI entrypoint, including `oura dashboard`,
  DNA explorer routes, blood PDF import, model runners, and local dashboard APIs.
- **`crates/oura-summary`**: shared dashboard summary JSON consumed by web and iOS.
- The always-on hub (summary snapshots, ring replica, Apple Health samples, MCP tools)
  lives in its own repo: [oura-hub](https://github.com/KenWuqianghao/oura-hub). The
  iOS app connects with one QR scan and pushes after every sync; `oura push` does the
  same from a Mac.
- **`crates/oura-core` / `crates/oura-ffi`**: native/iOS FFI surfaces.
- **`crates/oura-dna` + `dna/`**: local VCF trait/PGS scoring catalog and helpers.
- **`tools/`**: model runners and app-oriented analysis utilities.

## Boundary with open_oura

`open_health` depends on `open_oura` for:

- `oura-protocol`: packet framing, request builders, auth crypto, event decoders.
- `oura-link`: BLE transport/client and sync/live stream orchestration.
- `oura-store`: SQLite event/readings store.
- `oura-analysis`: portable metric algorithms.

Keep reusable protocol/library work in `open_oura`. Keep app UX, dashboard APIs,
iOS presentation, DNA, blood, and model orchestration here.

## Quick start (web dashboard)

```bash
cargo +1.93.0 run --release -p oura-cli -- dashboard \
  --tz-offset 1 \
  --dna-files <folder with your VCF files> \
  --blood-files <folder with your blood report PDFs>
```

Open `http://127.0.0.1:8090`.

The dashboard reads local files only. Genome files, blood PDFs, generated
`blood.db`, Oura auth keys, and raw captures should stay outside Git.

## Validation

```bash
cargo +1.93.0 test --workspace
```

For the iOS app, follow [`apps/ios/README.md`](apps/ios/README.md): it goes from a
clean Mac to a paired ring, Apple Health export, and background sync.

## Credits and license

MIT. The Oura protocol work, the event decoders, and the metric ports are
[open_oura](https://github.com/Th0rgal/open_oura) by Thomas Marchand. Not affiliated
with Oura.
