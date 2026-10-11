#!/bin/sh
# Run from repository root after supplying private .env values.
set -eu
mkdir -p .state/services
docker compose --profile maintenance build
docker compose up -d postgres
docker compose run --rm migrate
docker compose up -d --wait
