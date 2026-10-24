# ionoscope-infrastructure

Production-oriented infrastructure workspace for IonoScope.

The project is split into independently deployable services. Background
calculation is intentionally separated from user-facing requests:

- `data-api` serves station metadata and prepared feature tables.
- `data-update-worker` processes queued prepared-data update tasks.
- `station-discovery` checks the full catalog separately and publishes candidates.
- `ml-service` performs fast inference from prepared features.
- `api` serves user-facing forecast requests from cache when possible.
- `forecast-refresh-worker` refreshes forecast cache in the background.
- `gateway` is the only public entrypoint in production compose.

## Files

- `docker-compose.dev.yml` - local development/demo stand with service ports
  exposed for debugging.
- `docker-compose.prod.yml` - production-style runtime with private internal
  services, named volumes and restart policies.
- `.env.example` - environment template for production settings.
- `nginx/ionoscope.conf` - gateway routing to the public API.

## Local Development

From this directory:

```powershell
.\start.ps1
```

The script starts Docker Desktop if necessary and starts the existing
`ionoscope-api-check` Compose project. Use `./start.ps1 -NoBuild` for a quick
restart without rebuilding images. Stop services without deleting data with
`docker compose -f docker-compose.dev.yml -p ionoscope-api-check stop`.

Development uses three shared images: `ionoscope-data:dev` for the data API,
data worker and station discovery; `ionoscope-api:dev` for the forecast API
and refresh worker; and `ionoscope-ml-service:dev` for inference. Only the
three API services define builds. Rebuild after code changes with `./start.ps1`;
use `./start.ps1 -NoBuild` for ordinary starts. Rebuilds can leave old unused
image versions on disk even though the image names stay the same.

To restart Docker Desktop and bring the stack back up together, use
`./start.ps1 -RestartDocker -NoBuild`. In the checked Windows installation,
`docker desktop restart` alone left all containers stopped despite their
`unless-stopped` policy. The launcher explicitly starts Compose after the
engine is ready. API health does not mean the first live forecast cycle has
finished; check `/api/v1/live/status` for its result.

Open API docs:

```text
http://127.0.0.1:8000/docs
http://127.0.0.1:8001/docs
http://127.0.0.1:8002/docs
```

## Production-Style Run

Build and publish service images from their repositories, then prepare the
environment:

```powershell
Copy-Item .env.example .env
```

Edit `.env` with real image tags and runtime settings. Then run:

```powershell
docker compose --env-file .env -f docker-compose.prod.yml up -d
```

Only the gateway port is public. Internal service ports are not published.

## Background Flow

Compose automatically selects current stations and updates them every 300 seconds, starting immediately when
the API is healthy. `data-update-worker` collects GIRO + GFZ + NOAA RTSW, prepares
a new immutable feature generation, publishes its pointer atomically, then
refreshes the main API forecast/cache. The first pull covers 24 hours; subsequent
pulls recheck the last 3 hours for delayed observations. NOAA provides live solar
wind; historical OMNI is optional (`IONOSCOPE_LIVE_SOURCES=all` in a new workspace).
The automatic station set may change between cycles. Changing collection sources
requires a separate live-data workspace.

On failure the worker retries in 60 seconds. Empty/stale features are not
published; failed forecast refreshes preserve the last cache. The API still
enforces expiry and returns 503 when observations or the forecast are too old.
All services restart with Docker Engine (`unless-stopped`). Docker Desktop itself
must be running.

State/history persists in `ionoscope-data/live_data` in development and the
`data_live` volume in production. Immutable batches/generations are retained:
monitor disk usage and back them up. Live serving uses the committed generation;
explicit historical queue jobs continue writing their legacy preparation folders.

Inspect `http://localhost:8001/api/v1/live/status` for phase, last successful run,
cycle/failure counts and errors. Logs and service state:

```powershell
docker compose -f docker-compose.dev.yml -p ionoscope-api-check logs --tail 60 data-update-worker
docker compose -f docker-compose.dev.yml -p ionoscope-api-check ps
```

After a restart the next cycle runs immediately from the persisted collection
watermark. Updates share an OS lock. A collection timeout terminates the whole
collector process group inside Linux and releases its lock.

`station-discovery` checks the full current GIRO catalog on a 3600-second
schedule, including codes missing from the old local catalog. It publishes
candidate hints incrementally in `live_data/discovery/station_registry.json`.
The live worker checks only these candidates and previously prepared stations;
it does not fetch the full station form in each foreground cycle. Missing or
stale catalog hints cannot authorize serving an old forecast. On a fresh install,
live updates retry while discovery publishes its first eligible candidates.
A station qualifies only
with a finite foF2 in 0.5–25 MHz, CS >= 50, measured in a completed interval and
no more than 60 minutes old. New stations also require coordinates from the GIRO
response. The merged metadata is persisted without modifying the source catalog.
Only qualifying stations enter full collection; at most four GIRO requests run
concurrently. One failed station does not prevent other forecast refreshes.
Requests across both workers and collection subprocesses share one file-backed
rate gate. Foreground network requests reserve priority; background requests yield between
probes and never hold the rate lock while sleeping. Requests are spaced at least
6 seconds apart. HTTP 429 opens a shared cooldown of at
least 60 seconds (or Retry-After); it does not trigger burst retries.
Queued requests wait for that cooldown and recheck it before starting, including
when another in-flight request received 429 while they were waiting. The request
that received 429 remains a source error; stations still in the queue are
attempted after the pause instead of being marked unavailable without a request.
Verified activity checks can be reused for up to 10 minutes; source errors are rechecked.
Normal live cycles are scheduled 300 seconds from their start, rather than adding
the collection duration to the interval.

The full station audit is in `live_data/discovery/station_registry.json`.
The serving activity snapshot is in `live_data/station_registry.json`.
The live status API also reports foreground duration/next run and background status.
Network priority is released before CPU-only feature preparation, so discovery
can make progress while features and forecasts are being calculated. The last
completed cycle's duration is recorded as `duration_seconds`; `started_at` and
`phase` describe the current cycle.
The main forecast station list omits inactive entries. A direct forecast request
for an inactive station returns 503 even if its previous cache is still present.
An activity check expires after 30 minutes without a new scan, and observation
age is re-evaluated on every request. Failed preparation is not advertised as
available data. This verifies operational data availability, not per-station
forecast accuracy; model quality must be evaluated separately.
The forecast list additionally requires prepared features whose 15-minute forecast
target has not passed. An operational station with delayed data can remain in
the audit while being omitted from the list of currently available forecasts.

The station audit also includes `diagnosis`: no measurements in the checked
3-hour window, measurement rows with missing foF2, foF2 older than 60 minutes,
fresh foF2 rejected by CS, unknown CS, invalid physical values, or an incomplete
interval. Source failures and missing catalog entries are separate categories.
`reason` remains compatible with the operational station selector.

Prepared-data update tasks are created through `ionoscope-data` in development,
or through the private data API from an operator job in production:

```powershell
curl -X POST http://127.0.0.1:8001/api/v1/updates `
  -H "Content-Type: application/json" `
  -d "{\"station\":\"TR169\",\"start\":\"2025-01-01T00:00:00Z\",\"end\":\"2025-02-01T00:00:00Z\"}"
```

The `data-update-worker` picks queued tasks and writes prepared features. The
`forecast-refresh-worker` then calls `ionoscope-api` on a schedule and writes
fresh forecast cache files. User requests to `POST /api/v1/forecast` can return
a ready forecast without running the full data update path.

## Production Notes

- Store `.env` outside Git and keep real secrets out of this repository.
- Publish immutable image tags instead of using `latest` for real releases.
- Put TLS termination in front of `gateway` or extend the nginx config with
  certificates.
- Back up named volumes for raw data, prepared features, forecast cache and
  model artifacts.
- Keep `data-api`, `ml-service` and workers private; expose only `gateway`.


## API verification

The API checker covers all 17 business/liveness routes, documentation, error
schemas, cache recovery/concurrency, update-queue persistence and the real model.
Build test images with `docker compose -f docker-compose.dev.yml -p ionoscope-api-check build data-api ml-service api`,
then run `python scripts/check_stack.py --docker --report ../output/api_verification/full_stack_docker.json`
from ionoscope-api. The checker uses isolated data and removes temporary containers.
Add `--active-stations` for 69 scenarios covering production activity guards,
inactive stations with existing cache, expired targets and source failures.
See [the verification report](docs/verification-2026-10-24.md) for the checked
real-data cycle, station rechecks and the Docker restart behavior.

The production data-update-worker uses both the private backend network and an
outbound egress network to collect external observations. Other internal services
remain on the backend network. The gateway also forwards /redoc.
