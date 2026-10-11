#!/bin/sh
# Docker entry point: run a one-off bot command, or start cron in the foreground.
set -eu

ROOT=/app
cd "$ROOT"

mkdir -p var

# Provide a default config.toml when none is mounted, so --dry-run and --list
# work on a fresh image and the cron job has something to read.
if [ ! -f config.toml ]; then
  cp config.example.toml config.toml
  echo "docker-entrypoint: created config.toml from example" >&2
fi

# In a container, cron jobs do not inherit the environment variables passed to
# the container. If no .env is mounted, write one from the environment so the
# scheduled runs can read the credentials the same way the host binary does.
if [ ! -f .env ]; then
  if [ -n "${TELEGRAM_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
    printf 'TELEGRAM_TOKEN=%s\nTELEGRAM_CHAT_ID=%s\n' "$TELEGRAM_TOKEN" "$TELEGRAM_CHAT_ID" > .env
    chmod 600 .env
    echo "docker-entrypoint: created .env from environment variables" >&2
  fi
fi

# Any argument is treated as a bot option and executed once.
if [ $# -gt 0 ]; then
  exec "$ROOT/bin/differenziata-bot" "$@"
fi

# Daemon mode: install the managed cron block into a private crontab directory
# and run cron in the foreground so the container stays alive. tini runs as
# PID 1 because dcron calls setpgid, which fails for the root process.
mkdir -p var/crontabs
export CRONTAB_FILE="$ROOT/var/crontabs/root"
"$ROOT/bin/cron.sh" refresh
exec tini -- crond -f -c "$ROOT/var/crontabs"
