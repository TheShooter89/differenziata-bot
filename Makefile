LUA ?= lua
BIN := ./bin/differenziata-bot
CRON := ./bin/cron.sh

.PHONY: help test run dry-run list test-send cron-status cron-add cron-remove cron-start cron-stop cron-refresh setup

help:
	@echo "test        run the unit tests"
	@echo "dry-run     report due reminders, send nothing"
	@echo "list        print the upcoming collection calendar"
	@echo "test-send   send one real Telegram message"
	@echo "setup       create .env, config.toml and var/"
	@echo "cron-*      add/remove/start/stop/refresh/status for the crontab entry"

test:
	$(LUA) tests/run.lua

run:
	$(BIN)

dry-run:
	$(BIN) --dry-run --verbose

list:
	$(BIN) --list --days 21

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