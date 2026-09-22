# Health hub: an always-on MCP endpoint for your health data

The hub is a small server that runs 24 hours a day on a home server or a rented
VPS. Clients push the health summary to it. Agents (Grok Bot, Claude Code, any MCP
client) read the summary from it over MCP. Your Mac and your phone can be off.

The hub does not talk to the ring. It stores what a client pushed, and it serves
that. This keeps the ring's single Bluetooth link with the client that syncs it.

## Parts

| Part | Where | Job |
| --- | --- | --- |
| `oura-hub` | `crates/oura-hub` | HTTP server: `/ingest/summary`, `/mcp`, `/health` |
| `oura-summary::agent` | `crates/oura-summary/src/agent.rs` | Turns the full summary into the short documents the tools return |
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
| `OURA_HUB_DB` | `hub.db` | SQLite file for the snapshots |
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

## Push the summary

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

1. The iOS app pushes the summary itself, so the Mac is not needed.
2. The iOS app reads Apple Watch samples from HealthKit and adds them to the push.
3. HealthKit background delivery pushes within minutes of new Watch data.
