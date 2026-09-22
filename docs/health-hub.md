# Health hub: an always-on MCP endpoint for your health data

The hub is a small server that runs 24 hours a day on a home server or a rented
VPS. Clients push two things to it:

1. **The health summary** (`build_summary` JSON). Agents (Grok Bot, Claude Code, any
   MCP client) read it over MCP.
2. **The raw ring rows** (events, readings, device rows). The hub keeps them in its
   own `oura.db` with the `oura-store` schema. This is the backup: every report the
   phone or the desktop can run also runs on the hub's file.

Your Mac and your phone can be off. The hub does not talk to the ring. It stores
what a client pushed, and it serves that. This keeps the ring's single Bluetooth
link with the client that syncs it.

## Parts

| Part | Where | Job |
| --- | --- | --- |
| `oura-hub` | `crates/oura-hub` | HTTP server: `/ingest/summary`, `/ingest/events`, `/export/events`, `/mcp`, `/health` |
| `oura-summary::agent` | `crates/oura-summary/src/agent.rs` | Turns the full summary into the short documents the tools return |
| `oura-store::replication` | open_oura | `export_after` / `import_batch`: raw rows in pages, idempotent |
| iOS `HubPush.swift` | `apps/ios/OuraApp` | Pushes the summary and the new rows after each sync |
| `oura push` | `crates/oura-cli` | Builds the summary on the Mac and pushes it |

## Run the hub

Make a token. Keep it secret. The hub refuses tokens shorter than 16 characters.

```bash
openssl rand -hex 24
```

Run with Docker Compose from the repo root:

```bash
OURA_HUB_TOKEN=<token> docker compose up -d --build
```

Or run the binary:

```bash
OURA_HUB_TOKEN=<token> OURA_HUB_DB=/var/lib/oura/hub.db cargo run --release -p oura-hub
```

Environment:

| Variable | Default | Meaning |
| --- | --- | --- |
| `OURA_HUB_TOKEN` | required | Bearer token for pushes and for MCP |
| `OURA_HUB_BIND` | `0.0.0.0:8787` | Listen address |
| `OURA_HUB_DB` | `hub.db` | SQLite file for the summary snapshots |
| `OURA_HUB_RING_DB` | `oura.db` next to `OURA_HUB_DB` | The ring replica (`oura-store` schema) |
| `RUST_LOG` | `info` | Log filter |

Check it:

```bash
curl -s http://127.0.0.1:8787/health
```

## Put TLS in front

The hub speaks plain HTTP. Do not expose port 8787 to the internet as is.
Use one of these:

- **Tailscale**. Put the hub and the Mac on the same tailnet. Push to
  `http://<tailscale-ip>:8787`. Grok Bot on the Mac reaches the same address.
- **Caddy** (or any reverse proxy) with a real domain. Caddy gets a certificate for
  you. Example `Caddyfile`:

```text
hub.example.com {
    reverse_proxy 127.0.0.1:8787
}
```

## Push from the iPhone

Open Settings in the app. Under **Health hub** turn on **Send data to my hub**, enter
the hub URL and the token. After every sync the app sends:

- the summary, with the on-device model results folded in (sleep stages, cardio
  age, illness signs), and
- every ring row the hub does not have yet, in pages of 1000. The app remembers the
  last accepted ids, so a push that stops early loses nothing.

A background refresh has about 22 seconds. The push uses at most 8 of them. What
did not fit goes out on the next sync or the next app open. **Send Now** sends at
once. **Send All Ring Data Again** resets the ids, for a new hub.

The token is kept in the Keychain and is readable after the first unlock, so a
background sync on a locked phone can push.

## Push from the Mac

From the Mac that has `oura.db`:

```bash
export OURA_HUB_TOKEN=<token>
oura push --to https://hub.example.com --tz-offset 8
```

The command builds the same summary the dashboard shows, then posts it. A summary
that did not change is not stored twice. Run it after each `oura sync`, or on a
timer. The hub keeps the last 500 snapshots.

The reply shows what the hub stored:

```json
{ "stored": true, "generated_at": 1758500000.0, "received_at": 1758500012, "snapshots": 12 }
```

## The ring replica

`POST /ingest/events` takes an `oura-store::replication::ExportBatch` and imports it
into the hub's `oura.db`. Rows the hub already holds are ignored. `GET
/export/events?after_event_id=0&after_reading_id=0&limit=2000` (Bearer) gives the
rows back in pages, to restore a phone or a desktop.

The replica is a normal store. On the server:

```bash
oura dashboard --db /data/oura.db
```

`GET /health` shows `ring.max_event_id`; compare it with the app's "through id".

## Connect an agent over MCP

The MCP endpoint is Streamable HTTP with JSON replies. Two ways to authenticate:

- token in the path: `POST https://hub.example.com/mcp/<token>`
- bearer header: `POST https://hub.example.com/mcp` with `Authorization: Bearer <token>`

Grok Bot takes only a URL per server, so use the path form in its `mcpServers`:

```json
{
  "mcpServers": {
    "health": { "url": "https://hub.example.com/mcp/<token>" }
  }
}
```

Claude Code:

```bash
claude mcp add --transport http health https://hub.example.com/mcp/<token>
```

Test by hand:

```bash
curl -s https://hub.example.com/mcp/<token> -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_status_now","arguments":{}}}'
```

## Tools

| Tool | Arguments | Returns |
| --- | --- | --- |
| `get_status_now` | none | Last night, sleep debt, HRV and resting HR against baseline, illness signs, cardio age, today's activity, battery, and a `freshness` block |
| `get_sleep` | `days` (default 7) | Recent nights, newest first, without the per-epoch series |
| `get_trends` | `metric`, `days` (default 14) | One value per day, oldest first, with latest, mean, and baseline |
| `get_activity` | `days` (default 7) | Steps, active kcal, total kcal, distance per day |

Metrics for `get_trends`: `hrv_ms`, `rhr`, `skin_temp`, `efficiency`, `in_bed_h`,
`asleep_min`, `deep_pct`, `rem_pct`, `light_pct`, `wake_pct`, `awakenings`,
`waso_min`, `sol_min`, `steps`, `active_kcal`, `total_kcal`.

Every status carries `freshness`. The ring sends data at sync time, not live.
`ring_last_sync_age_h` is the age of the newest ring data. An agent should say
when the data is old, not plan on it.

## A planning prompt

Give the agent a daily trigger and a prompt like this:

> Call `get_status_now`. If `ring_last_sync_age_h` is above 12, say the data is old.
> Then plan my day: training load, when to stop caffeine, and a bedtime. Keep it short.

## Next steps

1. The iOS app reads Apple Watch samples from HealthKit and adds them to the push.
2. HealthKit background delivery pushes within minutes of new Watch data.
3. The hub builds the summary from its own replica when no summary was pushed.
