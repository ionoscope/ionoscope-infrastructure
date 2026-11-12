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
