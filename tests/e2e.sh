#!/usr/bin/env bash
# End-to-end check of the bot against a stub Telegram API: exercises config
# loading, schedule maths, reminder selection, sending and deduplication without
# touching the network or your real token.
#
#   bash tests/e2e.sh
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
WORK=$(mktemp -d)
PORT=${PORT:-18731}

cleanup() {
  [ -n "${server_pid:-}" ] && kill "$server_pid" 2>/dev/null
  [ -n "${reject_pid:-}" ] && kill "$reject_pid" 2>/dev/null
  [ -n "${getreject_pid:-}" ] && kill "$getreject_pid" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

failures=0
check() { # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"
    failures=$((failures + 1))
  fi
}

cat > "$WORK/stub_api.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

LOG, REJECT, REJECT_GET = sys.argv[2], "--reject" in sys.argv, "--reject-get" in sys.argv


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode("utf-8")
        with open(LOG, "a") as handle:
            handle.write("PATH " + self.path + "\nBODY " + body + "\n---\n")
        if REJECT:
            payload, code = json.dumps({"ok": False, "description": "stub rejected"}).encode(), 400
        else:
            payload, code = json.dumps({"ok": True, "result": {"message_id": 1}}).encode(), 200
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    # getUpdates for the command poller. One canned /planning update, and an
    # empty result once the offset has moved past it, so a second poll tick
    # genuinely has nothing new to answer.
    def do_GET(self):
        with open(LOG, "a") as handle:
            handle.write("PATH " + self.path + "\n---\n")
        if REJECT_GET:
            payload, code = json.dumps(
                {"ok": False, "description": "stub rejected getUpdates"}
            ).encode(), 400
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        query = parse_qs(urlparse(self.path).query)
        offset = int(query.get("offset", ["0"])[0] or 0)
        if offset > 5001:
            result = []
        else:
            result = [{
                "update_id": 5001,
                "message": {
                    "message_id": 1,
                    "chat": {"id": -100999, "type": "group"},
                    "text": "/planning",
                },
            }]
        payload = json.dumps({"ok": True, "result": result}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        pass


HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
PY

python3 "$WORK/stub_api.py" "$PORT" "$WORK/api.log" >/dev/null 2>&1 &
server_pid=$!
sleep 1

cp "$ROOT/schedule.csv" "$WORK/schedule.csv"
# Credentials live in .env next to config.toml, as in a real install.
cat > "$WORK/.env" <<EOF
TELEGRAM_TOKEN=111111:FAKE_TOKEN_FOR_LOCAL_TESTING
TELEGRAM_CHAT_ID=999999
EOF
cat > "$WORK/config.toml" <<EOF
[telegram]
api_base = "http://127.0.0.1:$PORT"
[calendar]
csv = "schedule.csv"
[runtime]
state_file = "var/state.tsv"
EOF

export DIFFERENZIATA_CONFIG="$WORK/config.toml"
bot() { "$ROOT/bin/differenziata-bot" "$@" 2>&1; }
api_calls() { [ -f "$WORK/api.log" ] && grep -c "^PATH" "$WORK/api.log" || echo 0; }

# --- dry run sends nothing ---------------------------------------------------
out=$(bot --dry-run --at 2026-10-04T11:35)
check "dry run does not call the API" "0" "$(api_calls)"
check "dry run does not write state" "0" "$(find "$WORK/var" -name state.tsv 2>/dev/null | wc -l)"
check "dry run still prints the message" "1" "$(printf '%s' "$out" | grep -c 'ritirano domani')"
check "dry run says nothing was really sent" "1" "$(printf '%s' "$out" | grep -c '1 would be sent')"

# --- a due reminder is sent --------------------------------------------------
bot --at 2026-10-04T11:35 >/dev/null
check "due reminder calls the API once" "1" "$(api_calls)"
check "state file is created" "1" "$(find "$WORK/var" -name state.tsv | wc -l)"
check "state records the 11:30 slot" "1" "$(grep -c '^2026-10-05|d1|11:30' "$WORK/var/state.tsv")"

# --- the same slot is not resent --------------------------------------------
bot --at 2026-10-04T11:40 >/dev/null
check "re-running does not resend" "1" "$(api_calls)"

# --- later slots of the same pickup day do fire ------------------------------
bot --at 2026-10-04T16:05 >/dev/null
check "the 16:00 slot fires" "2" "$(api_calls)"
bot --at 2026-10-04T20:35 >/dev/null
check "the 20:30 slot fires" "3" "$(api_calls)"
check "all three slots are in state" "3" "$(wc -l < "$WORK/var/state.tsv")"

# --- a tick before the due time is silent ------------------------------------
bot --at 2026-10-05T09:00 >/dev/null
check "a tick before the due time is silent" "3" "$(api_calls)"

# --- late tick inside the grace window still sends --------------------------
rm -rf "$WORK/var"
bot --at 2026-10-04T12:00 >/dev/null
check "a 30 minute late tick still sends" "4" "$(api_calls)"

# --- past the grace window it is reported missed, not sent ------------------
rm -rf "$WORK/var"
out=$(bot --at 2026-10-04T13:35)
check "past the grace window nothing is sent" "4" "$(api_calls)"
check "past the grace window it is logged as missed" "1" "$(printf '%s' "$out" | grep -c 'missed reminder')"

# Cron ticks every 30 minutes, so a miss must be recorded rather than re-reported
# on every tick for as long as the pickup stays in the horizon.
out=$(bot --at 2026-10-04T14:05)
check "a miss is not reported again on the next tick" "0" "$(printf '%s' "$out" | grep -c 'missed reminder')"
check "the second tick still sends nothing" "4" "$(api_calls)"

# --- a later reminder slot for the next pickup day ---------------------------
# The pickup day and its kinds are read out of schedule.csv rather than hardcoded,
# so editing the calendar cannot silently invalidate this check. The clock is
# pinned to a fixed date so the derivation does not depend on when the suite runs.
# Fields are: date, relative offset, emoji, then the kinds. The names contain
# spaces ("secco / non riciclabile"), so everything from the fourth field on is
# kept together rather than split on whitespace.
next_pickup=$(bot --list --days 30 --at 2026-10-04T00:00 | awk '/^20/ { $1 = $2 = $3 = ""; sub(/^ +/, ""); print; exit }')
next_day=$(bot --list --days 30 --at 2026-10-04T00:00 | awk '/^20/ { print $1; exit }')
next_kinds=$next_pickup
first_kind=${next_kinds%%,*}
# GNU date takes the last -d only, so the two flags must be one expression or
# the day is computed from "now" instead of from the pickup day.
reminder_day=$(LC_ALL=C date -d "$next_day -1 day" +%Y-%m-%d)
rm -rf "$WORK/var"
out=$(bot --at "${reminder_day}T11:35")
check "the next pickup day's reminder fires" "5" "$(api_calls)"
check "the message names that day's trash" "1" "$(printf '%s' "$out" | grep -c "$first_kind")"
check "the message names the pickup day" "1" \
  "$(printf '%s' "$out" | grep -c "$(date -d "$next_day" '+%-d %b' | sed 's/^ *//')")"

# --- the API rejecting a message is an error --------------------------------
# A second port rather than a restart of the first server: the old process may
# still hold the port, and the point here is the rejection, not the restart.
REJECT_PORT=$((PORT + 1))
python3 "$WORK/stub_api.py" "$REJECT_PORT" "$WORK/api.log" --reject >/dev/null 2>&1 &
reject_pid=$!
sleep 1
sed -i "s|api_base = \"http://127.0.0.1:$PORT\"|api_base = \"http://127.0.0.1:$REJECT_PORT\"|" "$WORK/config.toml"
rm -rf "$WORK/var"
bot --at 2026-10-04T11:35 >/dev/null
check "a rejected message calls the API" "6" "$(api_calls)"
check "a rejected message is not recorded as sent" "0" \
  "$(find "$WORK/var" -name state.tsv 2>/dev/null | wc -l)"
bot --at 2026-10-04T11:40 >/dev/null
check "a rejected message is retried on the next run" "7" "$(api_calls)"

# --- the token is never logged ----------------------------------------------
: > "$WORK/api.log"
bot --at 2026-10-04T11:35 --verbose > "$WORK/verbose.log" 2>&1
check "verbose logs redact the token" "0" "$(grep -c 'FAKE_TOKEN_FOR_LOCAL_TESTING' "$WORK/verbose.log")"
check "verbose logs do not dump .env" "0" "$(grep -c 'TELEGRAM_TOKEN=' "$WORK/verbose.log")"

# --- credentials are read from .env, in the documented order -------------------
# With no .env at all and nothing exported, the error must point at .env.
calls_before=$(api_calls)
rm -rf "$WORK/var" "$WORK/.env"
out=$(bot --verbose)
check "a run without credentials names .env as the fix" "1" \
  "$(printf '%s' "$out" | grep -c 'no bot token')"
check "a run without credentials sends nothing" "$calls_before" "$(api_calls)"

# An unedited .env must fail loudly rather than posting to a non-existent chat.
cp "$ROOT/.env.example" "$WORK/.env"
out=$(bot)
check "an unedited .env is rejected" "1" "$(printf '%s' "$out" | grep -c 'placeholder')"
check "an unedited .env sends nothing" "$calls_before" "$(api_calls)"

# A real exported variable beats the value in .env. The clock is pinned because
# this check depends on a reminder actually coming due, and without --at the
# suite would only pass when run inside one of the narrow grace windows.
printf 'TELEGRAM_TOKEN=111111:FAKE_TOKEN_FOR_LOCAL_TESTING\nTELEGRAM_CHAT_ID=999999\n' > "$WORK/.env"
rm -rf "$WORK/var"
out=$(TELEGRAM_TOKEN=222222:EXPORTED_TOKEN_WINS bot --verbose --at 2026-10-04T11:35)
check "an exported token overrides .env" "1" \
  "$(printf '%s' "$out" | grep -c '/bot<token>/sendMessage')"
check "the .env token is not used when exported" "0" \
  "$(printf '%s' "$out" | grep -c 'FAKE_TOKEN_FOR_LOCAL_TESTING')"

# --- the command poll: reply routing, chunking, dry run, failure retry -------
# The canned getUpdates is from the group chat -100999, the only id in
# commands.allowed_chat_ids, while TELEGRAM_CHAT_ID in .env is 999999: a reply
# must go back to the chat that asked, not to the configured one. Back to the
# accepting stub first: the rejection test above left api_base on the port that
# refuses every send.
printf '\n[commands]\nallowed_chat_ids = [-100999]\n' >> "$WORK/config.toml"
sed -i "s|api_base = \"http://127.0.0.1:$REJECT_PORT\"|api_base = \"http://127.0.0.1:$PORT\"|" "$WORK/config.toml"

# --- answer assertions -------------------------------------------------------
rm -rf "$WORK/var"
: > "$WORK/api.log"
bot --poll --at 2026-10-15 >/dev/null 2>&1
check "the poll exits 0" "0" "$?"
# The send body is urlencoded, so "Raccolte di Ottobre 2026" travels with '+' for
# each space.
check "the poll answers the command" "1" "$(grep -c 'PATH.*sendMessage' "$WORK/api.log")"
check "the reply names the current month" "1" "$(grep -c 'Raccolte+di+Ottobre+2026' "$WORK/api.log")"
# A concrete pickup day, derived from the calendar, so an empty-month reply
# cannot pass just by naming the month.
poll_day=$(bot --list --days 30 --at 2026-10-15 | awk '/^2026-10/ { print $1; exit }')
poll_dom=$(printf '%s' "$poll_day" | awk -F- '{ print $3 + 0 }')
check "the reply lists a concrete pickup day" "1" "$(grep -c "+${poll_dom}+ott" "$WORK/api.log")"
check "the reply goes to the requesting chat" "1" "$(grep -c 'chat_id=-100999' "$WORK/api.log")"
check "the reply never goes to the configured chat" "0" "$(grep -c 'chat_id=999999' "$WORK/api.log")"
check "the poll writes no reminder state" "0" "$(find "$WORK/var" -name state.tsv 2>/dev/null | wc -l)"
check "the offset advanced past the update" "5002" "$(cat "$WORK/var/updates.offset")"

bot --poll --at 2026-10-15 >/dev/null 2>&1
check "a second poll sends nothing new" "1" "$(grep -c 'PATH.*sendMessage' "$WORK/api.log")"
check "the second poll reads from the new offset" "1" "$(grep -c 'getUpdates.*offset=5002' "$WORK/api.log")"
check "the offset does not move again" "5002" "$(cat "$WORK/var/updates.offset")"

# A dry-run poll reads the stream (a read-only diagnostic) but sends nothing and
# writes no offset, so it cannot consume a command the next real tick should see.
rm -rf "$WORK/var"
: > "$WORK/api.log"
bot --poll --dry-run --at 2026-10-15 >/dev/null 2>&1
check "a dry-run poll exits 0" "0" "$?"
check "a dry-run poll reads the update stream" "1" "$(grep -c 'PATH.*getUpdates' "$WORK/api.log")"
check "a dry-run poll sends nothing" "0" "$(grep -c 'PATH.*sendMessage' "$WORK/api.log")"
check "a dry-run poll writes no offset" "0" "$(find "$WORK/var" -name updates.offset 2>/dev/null | wc -l)"

# The verbose poll log must not leak the token on the getUpdates path either.
rm -rf "$WORK/var"
out=$(bot --poll --verbose --at 2026-10-15 2>&1)
check "verbose poll redacts the token" "0" "$(printf '%s' "$out" | grep -c 'FAKE_TOKEN_FOR_LOCAL_TESTING')"

# --- chunking ----------------------------------------------------------------
# A dense calendar makes the month's plan longer than one Telegram message, so
# the poll loop's split-and-send runs end to end.
{
  echo "name,emoji,weekday,every_n_weeks,anchor_date,notes"
  for i in $(seq -w 1 200); do echo "rifiuto$i,,monday,1,2026-01-05,"; done
} > "$WORK/schedule.csv"
rm -rf "$WORK/var"
: > "$WORK/api.log"
bot --poll --at 2026-10-15 >/dev/null 2>&1
check "a long plan is split across messages" "1" \
  "$([ "$(grep -c 'PATH.*sendMessage' "$WORK/api.log")" -ge 2 ] && echo 1 || echo 0)"
check "the chunks cover the first pickup of the month" "1" "$(grep -c '+5+ott' "$WORK/api.log")"
check "the chunks cover the last pickup of the month" "1" "$(grep -c '+26+ott' "$WORK/api.log")"
check "no later poll body replies to the configured chat" "0" "$(grep -c 'chat_id=999999' "$WORK/api.log")"
cp "$ROOT/schedule.csv" "$WORK/schedule.csv"

# --- the offset advances only after a successful reply -----------------------
# A refused send must leave the offset alone so the next tick retries the command.
sed -i "s|api_base = \"http://127.0.0.1:$PORT\"|api_base = \"http://127.0.0.1:$REJECT_PORT\"|" "$WORK/config.toml"
rm -rf "$WORK/var"
: > "$WORK/api.log"
bot --poll --at 2026-10-15 >/dev/null 2>&1
reject_status=$?
check "a failed reply exits non-zero" "1" "$([ "$reject_status" -ne 0 ] && echo 1 || echo 0)"
check "a failed reply attempts exactly one send" "1" "$(grep -c 'PATH.*sendMessage' "$WORK/api.log")"
check "a failed reply writes no offset" "0" "$(find "$WORK/var" -name updates.offset 2>/dev/null | wc -l)"

sed -i "s|api_base = \"http://127.0.0.1:$REJECT_PORT\"|api_base = \"http://127.0.0.1:$PORT\"|" "$WORK/config.toml"
rm -rf "$WORK/var"
: > "$WORK/api.log"
bot --poll --at 2026-10-15 >/dev/null 2>&1
check "the retry exits 0" "0" "$?"
check "the retry answers the command" "1" "$(grep -c 'PATH.*sendMessage' "$WORK/api.log")"
check "the retry advances the offset" "5002" "$(cat "$WORK/var/updates.offset")"

# A refused getUpdates is the other half of the invariant: nothing is answered
# and the offset stays put, so the next tick tries again.
GETREJECT_PORT=$((PORT + 2))
python3 "$WORK/stub_api.py" "$GETREJECT_PORT" "$WORK/api.log" --reject-get >/dev/null 2>&1 &
getreject_pid=$!
sleep 1
sed -i "s|api_base = \"http://127.0.0.1:$PORT\"|api_base = \"http://127.0.0.1:$GETREJECT_PORT\"|" "$WORK/config.toml"
rm -rf "$WORK/var"
: > "$WORK/api.log"
bot --poll --at 2026-10-15 >/dev/null 2>&1
get_status=$?
check "a rejected getUpdates exits non-zero" "1" "$([ "$get_status" -ne 0 ] && echo 1 || echo 0)"
check "a rejected getUpdates sends nothing" "0" "$(grep -c 'PATH.*sendMessage' "$WORK/api.log")"
check "a rejected getUpdates writes no offset" "0" "$(find "$WORK/var" -name updates.offset 2>/dev/null | wc -l)"
sed -i "s|api_base = \"http://127.0.0.1:$GETREJECT_PORT\"|api_base = \"http://127.0.0.1:$PORT\"|" "$WORK/config.toml"

# A corrupt offset is refused rather than silently misread.
mkdir -p "$WORK/var"
printf '99999999999999999999999\n' > "$WORK/var/updates.offset"
bot --poll --at 2026-10-15 >/dev/null 2>&1
check "a corrupt offset is refused" "1" "$?"

printf '\n%s failures\n' "$failures"
[ "$failures" -eq 0 ]