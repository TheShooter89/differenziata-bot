# AGENTS.md

Guidance for AI agents working in this repository.

## What this project is

A single-purpose Lua cron job. It reads a recycling calendar from `schedule.csv`,
and sends a Telegram reminder telling the user which bins to leave out the day
before the collection truck comes. Pure Lua 5.x plus `curl`, no runtime
dependencies, designed to sit in a crontab unattended.

It is **not** a general-purpose scheduler. The whole domain is: given a calendar
of pickup days and a reminder policy, work out what to send right now and make
sure each reminder is sent exactly once.

## Commands

```sh
make test                    # unit tests, no network
make list                    # preview the next 21 days, needs no token
make dry-run                 # report what would be sent right now
bash tests/cron_lifecycle.sh # cron.sh lifecycle against a temp crontab
bash tests/e2e.sh            # full send/dedupe flow against a stub API

bin/differenziata-bot --dry-run --at 2026-10-04T11:35 --verbose
bin/cron.sh status
```

`--at` is the important one: it pins the clock so reminder timing can be tested
for an arbitrary moment instead of waiting for it.

Before calling a change done, all three suites must pass and `luac -p` must be
clean on every file in `src/`:

```sh
for f in src/*.lua; do luac -p "$f" || echo "SYNTAX $f"; done
```

## Invariants

Do not break these; each one has a test that will catch it.

- **`--dry-run` sends nothing and writes no state.** If it touched `state.tsv`,
  the next real run would consider those reminders already dealt with and stay
  silent forever.
- **Every reminder is recorded once, whether sent or missed.** `state.tsv` keys
  are the slot (`date|days_before|HH:MM`); a miss is stored under `missed|` plus
  that key. Without the miss record, cron would re-log the same miss on every
  30-minute tick while the pickup stayed in the horizon. A miss must not be
  recorded as a *send*: `was_missed` and `was_sent` are deliberately separate.
- **Nothing outside the crontab marker block is modified.** `bin/cron.sh` reads
  the whole crontab into a temp file before writing, because when `CRONTAB_FILE`
  is set the write truncates the file being read.
- **No `os.time` in calendar maths.** `src/date.lua` converts between dates and
  day numbers with integer arithmetic (Hinnant's algorithm), so the schedule is
  timezone-independent and testable. `os.time` is used in exactly two places:
  turning a wall-clock reminder time into a timestamp, and reading "now".
- **The token is never logged.** `telegram.redact` strips it from verbose output,
  and nothing prints the contents of `.env`. The token travels in the URL because
  that is what the Bot API requires; do not "improve" this by moving it into a
  header without also updating `redact`.
- **Every argument passed to a shell is quoted** with `util.shell_quote`. Message
  text contains spaces, parentheses and emoji that a shell will otherwise
  mangle.
- **`curl`, not LuaSocket.** LuaSocket is present on this machine and does not
  verify TLS by default, which is unacceptable for a client holding a bot token.
  Do not "simplify" this into a `require("socket.http")`.
- **`isdst` is left unset** on `os.time` calls that resolve a reminder time.
  Forcing `isdst = false` shifts every reminder by an hour for half the year.

## Layout and ownership

```
bin/differenziata-bot   sh wrapper: absolute paths, fixed PATH, flock
bin/cron.sh             crontab lifecycle, bash
bin/setup               config bootstrap
src/toml.lua            self-contained TOML reader
src/dotenv.lua          self-contained .env reader
src/csv.lua             self-contained CSV reader
src/date.lua            civil-date arithmetic
src/schedule.lua        pickup-day maths, CSV validation
src/reminders.lua       due-time slots, message text
src/state.lua           sent-reminder ledger (TSV)
src/telegram.lua        Bot API over curl
src/config.lua          defaults, merging, validation
src/init.lua            CLI and orchestration
```

`toml.lua`, `dotenv.lua` and `csv.lua` are deliberately vendored rather than
installed from luarocks. Nothing in this repo requires a rock.

Module boundaries are strict: `reminders.lua` requires `config.lua` only for
`is_array`, and nothing requires `init.lua`.

## Error handling conventions

- Parsers and loaders return `nil, message` where `message` is already
  human-readable, including the file and line.
- `init.lua` funnels that through `fail(message)`, which writes to stderr and
  exits 1. There is no error-handling framework.
- Unknown CLI options exit 2, distinct from a runtime failure at 1.
- `cron.sh status` exits 0 enabled / 1 disabled / 2 not installed, so it works
  as a health check.

A single-return-value parse function whose second return is a table of values is
a trap in Lua, because the error slot silently overlaps a value slot. `date.lua`
has `parse` (three values or `nil, err`) and `parse_parts` (a table or
`nil, err`) for exactly this reason; prefer `parse_parts` when you only need to
check success.

## Config and secrets

`.env` holds the bot token and chat id and is gitignored; `.env.example` is the
committed template with `REPLACE_WITH_...` placeholders. `config.toml` holds
settings only and is also gitignored. Validation rejects an unedited placeholder
explicitly, so a fresh clone fails with a clear message rather than posting to a
non-existent chat.

Credentials resolve lowest to highest: `config.toml`, then `.env` beside the
config file, then a real exported variable. Do not "simplify" this into one
source; the exported-variable override is deliberate and tested in
`tests/e2e.sh`.

Never commit `.env`, `config.toml`, `var/`, or a real token. `bin/setup` creates
both config files at mode 600 and `var/` mode 700.

## Testing

Three suites, all runnable from the repo root with no setup:

| suite | covers | network |
| --- | --- | --- |
| `lua tests/run.lua` | units: toml, dotenv, csv, date, schedule, reminders, state, config | none |
| `bash tests/cron_lifecycle.sh` | `cron.sh` add/start/stop/refresh/remove | none |
| `bash tests/e2e.sh` | real sends, dedupe, grace window, API errors, credential resolution | loopback only |

`tests/e2e.sh` spins up a Python HTTP stub and points `api_base` at it. It must
keep using a fresh temp dir and must not reach the real API. `tests/run.lua`
discovers modules from an explicit list; add new files there.

Tests assert on the exact strings the user sees. Italian weekday and month
abbreviations in `date.lua` are asserted literally, so changing them breaks a
test on purpose: if you change one, change the message assertions with it.

`tests/helpers.lua`'s `matches` is a **plain substring** search, not a Lua
pattern. Error messages contain `-`, which is pattern magic, so pattern
semantics would silently fail to match.

## Environment

- Lua 5.4 is `lua`; `luajit` is also installed. No luarocks packages are
  installed for this project, and none are needed.
- `shellcheck` and `shfmt` are **not installed**. Check shell scripts with
  `bash -n` / `sh -n`.
- The working directory is on a mount that **forces the exec bit**, so git
  intermittently reports mode-only changes (`100644` → `100755`) with no content
  diff. `chmod 644` normalises it. Check `git diff` before assuming content
  changed.
- Shell is **zsh**; error messages from the system are in Italian.
- `tests/e2e.sh` binds a TCP port on 127.0.0.1. If it fails to start, an old
  stub may still hold the port; the script uses `PORT + 1` for its second stub
  for this reason.

## Conventions

- **2-space indent**, `local function`, `snake_case`. Match the file you edit.
- **Comment the why, not the what.** The load-bearing comments are the ones
  explaining a non-obvious choice (see Invariants). Do not add restatements of
  the code.
- Public functions return `value` or `nil, error_message`; `error()` with a level
  is reserved for the vendored parsers, which are called through `pcall`.
- Errors are lowercase sentences without trailing punctuation.

## Commits

Short imperative subject, matching the repo's own history. Only commit when the
user asks. Check `git status` first — `.env`, `config.toml` and the contents of
`var/` are ignored; only `var/.gitkeep` is tracked, so a fresh clone has the
directory without shipping any state.