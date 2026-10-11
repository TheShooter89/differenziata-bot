LUA ?= lua
BIN := ./bin/differenziata-bot
CRON := ./bin/cron.sh
DOCKER_IMAGE ?= differenziata-bot

.PHONY: help test run dry-run list poll test-send cron-status cron-add cron-remove cron-start cron-stop cron-refresh setup docker-build docker-test docker-dry-run docker-up docker-down

help:
	@echo "test        run the unit tests"
	@echo "dry-run     report due reminders, send nothing"
	@echo "list        print the upcoming collection calendar"
	@echo "poll        answer Telegram commands (/planning, /help) once"
	@echo "test-send   send one real Telegram message"
	@echo "setup       create .env, config.toml and var/"
	@echo "cron-*      add/remove/start/stop/refresh/status for the crontab entries"
	@echo "docker-*    build, test or run the container"

test:
	$(LUA) tests/run.lua

run:
	$(BIN)

dry-run:
	$(BIN) --dry-run --verbose

list:
	$(BIN) --list --days 21

poll:
	$(BIN) --poll

test-send:
	$(BIN) --test-send

setup:
	./bin/setup

cron-status:
	$(CRON) status

cron-add:
	$(CRON) add

cron-remove:
	$(CRON) remove

cron-start:
	$(CRON) start

cron-stop:
	$(CRON) stop

cron-refresh:
	$(CRON) refresh

docker-build:
	docker build -t $(DOCKER_IMAGE) .

docker-test:
	docker run --rm --entrypoint make $(DOCKER_IMAGE) test

docker-dry-run:
	docker run --rm $(DOCKER_IMAGE) --dry-run --verbose --at 2026-10-04T11:35

docker-up:
	docker compose up -d

docker-down:
	docker compose down
