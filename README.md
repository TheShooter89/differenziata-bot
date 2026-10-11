# differenziata-bot

A small Lua cron job that reads your recycling calendar from a CSV file and
reminds you, on Telegram, which bins to leave out the day before the truck
comes.

No runtime dependencies: plain Lua 5.x and `curl`.

## How it works

1. `schedule.csv` describes which kind of trash is collected on which weekday,
   and for anything collected every two weeks, which dates it happens.
2. `.env` holds your Telegram token and chat id. `config.toml` says how many
   reminders you want, at what times of day, and how many days before the pickup.
3. A cron entry runs the bot every 30 minutes. Each run sends any reminder that
   has come due and has not been sent yet.
4. A second cron entry runs `--poll` once a minute, so `/planning` and `/help`
   get an answer without waiting for the next reminder.

Three reminders the day before pickup, by default: late morning, afternoon and
evening.

```
🗑 Differenziata: ritirano domani (lun 5 ott)
Lascia fuori entro stasera / domani mattina.
- 📄 carta
- 🧴 plastica e lattine
```

## Telegram commands

The bot also answers commands, so you can ask for the month's plan at any time
instead of waiting for a reminder:

```
📅 Raccolte di Ottobre 2026
lun 5 ott: 📄 carta, 💩️ umido
mar 6 ott: 🧴 plastica e lattine
mer 7 ott: 🍾 vetro
...
```

| command | reply |
| --- | --- |
| `/planning` | the current month |
| `/planning 2026-11` | a specific month |
| `/planning prossimo` | the next month |
| `/help` | the command list |

Replies are plain text, so a name like `secco / non riciclabile` is never mangled
by a markup parser, and a long plan is split across messages on line boundaries.
Only the chat id in `.env` may talk to the bot unless you list more in
`commands.allowed_chat_ids`; messages from any other chat are ignored silently.

A second cron line polls for new commands once a minute. Each tick runs
`bin/differenziata-bot --poll`, which reads new updates, answers them, and records
how far it has read in `var/updates.offset`. The offset only moves after a reply
was actually sent, so a failed send is retried on the next tick.

## Setup

```sh
make setup                        # creates .env and config.toml (mode 600) and var/
```

Then edit `.env` and paste in the token from [@BotFather](https://t.me/BotFather)
and your chat id:

```sh
$EDITOR .env
```

To find your chat id, message the bot and open
`https://api.telegram.org/bot<TOKEN>/getUpdates`, or add it to a group and read
the group id the same way.

Check the calendar matches your municipality:

```sh
make list                         # the next 21 days, with reminder times
```

Send yourself a test message, then install the cron job:

```sh
make test-send
make poll                         # answer any command you have queued
make cron-add
make cron-status
```

The token never leaves the machine except in the request to Telegram, and it is
redacted from the logs. `.env` is gitignored.

## Docker

Build once, then run any bot command in a container:

```sh
make docker-build
make docker-dry-run
make docker-test
```

To run the bot continuously, create `.env` with your credentials and start the
container:

```sh
make docker-up
make docker-down
```

`docker-compose.yml` mounts `./var` so `state.tsv` and `updates.offset` survive
restarts. It expects `TELEGRAM_TOKEN` and `TELEGRAM_CHAT_ID` from `.env` in the
project directory (compose reads them for variable substitution). You can also
mount your own `config.toml` and `schedule.csv` by uncommenting the volumes in
`docker-compose.yml`.

Set your timezone with `TZ`, e.g. `TZ=Europe/Rome make docker-up`. The default
is `Europe/Rome`.

## Credentials

`.env`, created by `make setup`:

```sh
TELEGRAM_TOKEN=123456:ABC...
TELEGRAM_CHAT_ID=12345678
```

Values may be quoted, and `export KEY=value` lines are accepted. They are
resolved in this order, lowest priority first:

1. `config.toml` — still honoured, but not where credentials belong
2. `.env`, found next to the config file
3. a real exported environment variable, which wins

So an export overrides `.env` for a single run, which is handy for sending to a
different chat without editing the file:

```sh
TELEGRAM_CHAT_ID=-1001234567890 bin/differenziata-bot --test-send
```

An unedited `.env` copied from `.env.example` is rejected with a clear error
rather than posting to a non-existent chat.

## Configuration

`config.toml` holds settings only. All keys are optional:

```toml
[telegram]
# api_base = "https://api.telegram.org"
# timeout_seconds = 20
# retries = 2

[reminders]
days_before = 1                  # or a list, e.g. [2, 1] for a heads-up too
times = ["11:30", "16:00", "20:30"]
grace_minutes = 120              # how late a reminder can still be sent

[calendar]
csv = "schedule.csv"

[runtime]
state_file = "var/state.tsv"     # which reminders were already dealt with
offset_file = "var/updates.offset"  # how far the command poll has read

[cron]
schedule = "*/30 * * * *"        # used by bin/cron.sh

[commands]
poll_schedule = "* * * * *"      # how often the bot checks for commands
poll_timeout_seconds = 0         # 0: return at once; 30-60 for a long poll
allowed_chat_ids = []            # empty: only TELEGRAM_CHAT_ID may talk
```

To keep the token off disk entirely, export it instead and leave `.env` out of
the picture:

```sh
TELEGRAM_TOKEN=... TELEGRAM_CHAT_ID=... bin/differenziata-bot
```

## The calendar file

`schedule.csv` holds one row per kind of trash:

```csv
name,emoji,weekday,every_n_weeks,anchor_date,notes
carta,📄,monday,1,2026-01-05,
plastica e lattine,🧴,monday,1,2026-01-05,
umido,💩️,thursday,1,2026-01-01,
vetro,🍾,thursday,2,2026-01-15,ogni due settimane
secco / non riciclabile,🗑,friday,1,2026-01-02,
```

| column | meaning |
| --- | --- |
| `name` | what gets written in the message |
| `emoji` | optional, shown before the name |
| `weekday` | `monday`..`sunday`, or `1`..`7` |
| `every_n_weeks` | `1` for weekly, `2` for every other week |
| `anchor_date` | a date on that weekday that **is** a pickup; it fixes the phase of the cycle |
| `notes` | ignored by the bot, free for you |

Rows collected on the same day are grouped into a single message, so adding more
kinds of trash does not mean more messages.

Changing `anchor_date` shifts that row's whole cycle, so you can realign a
fortnightly row with your municipality's calendar.

## Command line

```
bin/differenziata-bot [options]

  -n, --dry-run          report what would be sent, send nothing
      --at TIME          pretend the current time is TIME (YYYY-MM-DDTHH:MM)
  -l, --list             print the upcoming calendar and exit
  -d, --days N           how many days to look ahead (default 14)
      --poll             answer Telegram commands (/planning, /help) once and exit
      --poll-timeout N   seconds a --poll may wait for updates (default 0: return at once)
      --test-send        send one test message and exit
      --config PATH      config file to use
  -v, --verbose          log every step
  -h, --help             usage
```

`--at` is the reason `--dry-run` is trustworthy: it lets you check a specific
moment without waiting for it.

```sh
bin/differenziata-bot --dry-run --at 2026-10-04T11:35 --verbose
```

## Managing the cron job

```sh
bin/cron.sh add       # install the entries (refuses if already installed)
bin/cron.sh status    # installed? enabled? plus the last 10 log lines
bin/cron.sh stop      # disable: comments the lines out
bin/cron.sh start     # enable: uncomments them
bin/cron.sh refresh   # re-read the schedules, rotate the log
bin/cron.sh remove    # delete the entries
```

`stop`/`start` are the pause/resume pair; neither loses the entries or their
settings. The entries live between marker comments and the script only ever
rewrites that block, so your other cron jobs are untouched. The previous crontab
is copied to `var/crontab.backup` before any change.

The managed block holds two lines: the reminder run and the command poll
(`--poll`). After changing `cron.schedule`, `commands.poll_schedule` or
`commands.poll_timeout_seconds`, run `bin/cron.sh refresh`. Installs made before
the `/planning` command existed need that refresh too, since their block has no
poll line yet. Note that `refresh` keeps the job stopped if you had stopped it.

`status` exits `0` when the job is installed and enabled, `1` when installed but
disabled, and `2` when not installed, so it is usable from a health check.

Runtime files:

| path | what |
| --- | --- |
| `var/cron.log` | stdout and stderr of every run |
| `var/bot.lock` | `flock` file, so two runs never overlap |
| `var/state.tsv` | reminders already dealt with, pruned after 90 days |
| `var/updates.offset` | how far the command poll has read the update stream |

## Tests

```sh
make test                    # unit tests (no network)
bash tests/cron_lifecycle.sh # cron.sh against a throwaway crontab
bash tests/e2e.sh            # the bot against a stub Telegram API
```

`tests/e2e.sh` starts a local HTTP stub, so it exercises real sends, retries,
deduplication and command polling without network access or your real token.
`tests/cron_lifecycle.sh` sets `CRONTAB_FILE` to a temp file, so it never touches
your real crontab.

## Layout

```
bin/differenziata-bot   cron-safe wrapper: fixed PATH, sets LUA_PATH, takes the lock
bin/cron.sh             add/remove/start/stop/status/refresh
bin/setup               one-time config bootstrap
src/init.lua            entry point and CLI
src/config.lua          defaults, merging and validation
src/toml.lua            TOML reader
src/dotenv.lua          .env reader for the credentials
src/csv.lua             CSV reader
src/date.lua            calendar arithmetic
src/schedule.lua        which days a given trash is collected
src/reminders.lua       due-time computation and message text
src/state.lua           sent-reminder ledger
src/telegram.lua        Bot API over curl
src/json.lua            strict JSON decoder for the getUpdates payload
src/plan.lua            monthly plan renderer
src/commands.lua        Telegram command dispatch
src/util.lua            logging and small helpers
```

No dates in the calendar logic go through `os.time`: `src/date.lua` converts
between dates and day numbers with integer arithmetic, so the schedule cannot be
affected by the machine's timezone. `os.time` is only used to turn a wall-clock
reminder time into a timestamp.