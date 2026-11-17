# Shared NFL feed service

The collector discovers games centrally, polls active box scores every second, and persists snapshots and play identities in SQLite. App requests read the cached feed; they never call Tank01. One hundred readers cost the same Tank01 request count as one reader.

## Run locally

    python3 backend/server.py

The service binds to 127.0.0.1:8787 by default. The iPhone simulator's Live Feed connects automatically. A physical iPhone needs the eventual hosted HTTPS URL (Feed connection in the app's gear menu).

Configuration:

- TANK01_API_KEY: provider key. Locally, the existing external ~/.config/my_first_app/tank01.env is used if the environment variable is absent.
- FEED_DB_PATH: defaults to ~/.local/share/my_first_app/feed.sqlite; use a persistent volume when hosted.
- BIND_HOST: default 127.0.0.1; deployment uses 0.0.0.0.
- PORT: default 8787, or the hosting provider's assigned port.

No credentials, databases, or request headers belong in GitHub. Server errors return generic descriptions, never provider error bodies or headers.

## Collection behavior

- Schedule discovery every 60 seconds for today and yesterday in US Eastern time.
- Poll in-progress games every second, with up to eight parallel requests and no overlapping collection cycles.
- Tank01 schedule status can lag. A scheduled game whose kickoff time has passed gets a box-score probe every 30 seconds until live; live box scores override stale Scheduled responses.
- Stop after the final box score. Keep stored data on disk; finished-game feeds remain visible for 24 hours.
- Failed requests back off; 429 pauses collection for a minute, and 401/403 for five minutes. Cached data remains readable.
- A SQLite lease prevents two collectors using the same database from duplicating requests. Run one instance with its persistent volume; independent replicas/databases would collect independently.
- Keep player ID/name indexes for 24 hours. Refresh league scoring, roster ownership, co-owners, and starters every minute. Exact ESPN ID matches are preferred. Exact normalized name + NFL team matches are used only if unambiguous.
- The app calculates per-play points from the shared snapshots and shared league rules. It makes no direct Tank01 or Sleeper calls in the Live Feed tab. Starters show total + play change; bench players show only total. Other app tabs may use Sleeper separately.

Each active game uses approximately 3,600 Tank01 requests per hour, plus up to 120 schedule requests per hour. Polls never overlap; slow responses may reduce the achieved refresh frequency. The backend continues collecting when apps are closed, while the service process is running.

## Read API

- GET /health: health and collector heartbeat.
- GET /api/feed: cached games, player sequence IDs, scoring and ownership, freshness, and collector status.

The old pass-through endpoints have been removed. No client endpoint can trigger upstream polling. The feed returns up to 24 hours of game snapshots; the app displays the 300 newest received plays across games.

## Render deployment (prepared, not deployed)

The repository's render.yaml defines one Docker web service, a one-GB persistent disk, a health check, and a secret prompt. It uses a paid Starter instance because collection must continue while users are offline. Confirm current hosting cost before creating it.

1. Install/connect the Render integration in Codex, or open Render and create a Blueprint from rontonshop/my_first_app.
2. Review render.yaml. Enter a rotated TANK01_API_KEY in Render's secret configuration. Never commit its value.
3. Deploy and verify /health and /api/feed on the returned HTTPS URL.
4. Enter that HTTPS origin in the app's Feed connection. A future release can set the FeedServerURL Info.plist value so no setup is needed.

The service is a single-instance starting architecture, not a horizontally scaled production deployment. Before scaling, move storage/collector locking to shared infrastructure. The cached read API is public-read and accepts no write or provider-fetch operations.

Official references:
- https://www.tank01.com/Guides_Game_Status_Code_NFL.html
- https://render.com/docs/blueprint-spec
- https://render.com/docs/disks

## Checks

    python3 -m unittest discover -s backend -v

Checks use a fake provider and temporary SQLite databases. They verify shared reads do not consume Tank01 calls, active-only polling, stale schedule fallback, finals, lease ownership, retries, persistence, corrected/deleted play identities, and starter/bench/co-owner mapping.

The current comparison build defaults to one-second refreshes. Backend POLL_SECONDS can override the interval (minimum one second); the app follows refresh_seconds returned by the server. Provider publication delays and slow requests still limit update speed.

## Direct Sleeper totals

The collector now reads league matchups for the current Sleeper week and publishes players_points values unchanged in sleeper_points. Scores refresh centrally at the active polling interval while games are active, and once a minute otherwise. Zero/negative values and bench scores are preserved; missing players remain unavailable. The app verifies week and NFL season before showing a Sleeper total. It does not substitute calculated box-score totals. Per-play Tank01 changes remain explicitly labeled estimates. The score refresh timestamp is visible in the feed.
