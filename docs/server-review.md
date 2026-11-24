# IonoScope server review

Use a Linux x86-64 server with Docker and Docker Compose. Download and extract
`ionoscope-review-linux-amd64.tar.gz` from the `review-v1` release, then run:

```sh
docker load -i images.tar.gz
docker compose up -d --pull never
```

Open the server address on port 80. Set `IONOSCOPE_HTTP_PORT=8080` in the
Compose environment if port 80 is occupied. Check `/health` and `/docs` on
that address. The live collector needs outbound internet access and publishes
forecasts once it has collected and prepared qualifying observations.
The bundle includes the built frontend and both frozen model artifacts.
It starts with an empty forecast archive. LLM explanations require provider
settings and are optional.

For startup diagnostics run `docker compose ps` and
`docker compose logs --tail=100 data-update-worker forecast-refresh-worker`.

## Updating an existing installation

Publishing images to GHCR does not itself update the server. Download the newly
built bundle, load `images.tar.gz`, and run Compose from the same installation
directory with the same project name so that existing volumes remain attached.
Do not use `docker compose down -v`: that deletes the stored data.

The data, API and ML images now run as UID 10001. When upgrading an installation
whose existing data was written by root, stop its services and migrate ownership
once before starting the updated images:

```sh
docker compose stop
docker compose run --rm --no-deps --user 0 --entrypoint sh data-api -c 'chown -R 10001:10001 /app/live_data /app/data /app/cleaned /app/normalized /app/features /app/update_tasks'
docker compose run --rm --no-deps --user 0 --entrypoint sh api -c 'chown -R 10001:10001 /app/forecast_cache'
docker compose run --rm --no-deps --user 0 --entrypoint sh model-shadow-worker -c 'chown -R 10001:10001 /app/shadow_data'
docker compose up -d --pull never
```

New installations use writable volumes without this migration. Check
`docker compose ps`, `/health` and collector logs after updating. New forecast
responses include observation age and daily coverage; previously cached
forecasts gain coverage after the next successful recalculation. Request timing
logs are under `/app/live_data/batches/<batch>/logs/collection_events.jsonl`;
distinct GIRO start and completion times are recorded only by the new version.

## Automatic updates

Merging a change to the pinned revisions, `compose.review.yml` or `nginx/` into
`main` publishes new `review-v1` images to GHCR. The images are private, so the
server needs a classic GitHub token with only the `read:packages` scope, from an
account that can read the `ionoscope` packages. Store it once for the user who
runs Compose:

```sh
docker login ghcr.io -u <github-user> --password-stdin < token.txt
chmod 600 ~/.docker/config.json
```

Watchtower reads that login from `~/.docker`. Set `IONOSCOPE_REGISTRY_AUTH_DIR`
in `.env` when the login is stored elsewhere. Renew the token before it expires,
or updates stop with an authentication error in the Watchtower log.

The optional `watchtower` service installs those images. It checks GHCR every
five minutes, recreates only containers labelled with the `ionoscope` scope,
and removes the images they replaced. Other containers on the host are left
alone. Enable it once from the installation directory after the installation
already runs the current images and their volume ownership is migrated:

```sh
echo COMPOSE_PROFILES=autoupdate >> .env
docker compose up -d --pull never
```

Watchtower replaces images, not the Compose file. When a change adds or
removes services, volumes or settings, copy the new `compose.yml` into the
installation directory and run `docker compose up -d` once. Check progress with
`docker compose logs --tail=50 watchtower`.
