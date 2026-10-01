#!/usr/bin/env bash
# Exercises bin/cron.sh against a throwaway crontab file, so it never touches
# the real one. Run from anywhere:  bash tests/cron_lifecycle.sh
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

export CRONTAB_FILE="$WORK/crontab"
export CONFIG_FILE="$WORK/config.toml"

failures=0
check() { # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"
    failures=$((failures + 1))
  fi
}

cron() { "$ROOT/bin/cron.sh" "$@"; }
lines() { grep -c "$1" "$CRONTAB_FILE" || true; }

printf '# other job\n*/5 * * * * /usr/bin/backup.sh\n' > "$CRONTAB_FILE"
printf '[cron]\nschedule = "*/20 * * * *"\n' > "$CONFIG_FILE"

# --- add ---------------------------------------------------------------------
cron add >/dev/null 2>&1
check "add exits 0" "0" "$?"
check "add installs exactly one block" "1" "$(lines '>>> differenziata-bot >>>')"
check "add installs exactly one end marker" "1" "$(lines '<<< differenziata-bot <<<')"
check "add keeps other cron jobs" "1" "$(lines 'backup.sh')"
check "add refuses to run twice" "1" "$(cron add >/dev/null 2>&1; echo $?)"
check "add refuses twice without duplicating" "1" "$(lines '>>> differenziata-bot >>>')"

# --- status ------------------------------------------------------------------
cron status >/dev/null 2>&1
check "status exits 0 when enabled" "0" "$?"

# --- stop / start ------------------------------------------------------------
cron stop >/dev/null 2>&1
check "stop exits 0" "0" "$?"
check "stop comments the command line" "1" "$(lines '^# DIFFERENZIATA_BOT=1')"
check "stop keeps other cron jobs" "1" "$(lines 'backup.sh')"
cron status >/dev/null 2>&1
check "status exits 1 when disabled" "1" "$?"

cron start >/dev/null 2>&1
check "start exits 0" "0" "$?"
check "start uncomments the command line" "1" "$(lines '^DIFFERENZIATA_BOT=1')"
check "start does not double-comment" "0" "$(lines '^# # DIFFERENZIATA_BOT')"

# --- refresh -----------------------------------------------------------------
sed -i 's|\*/20 \* \* \* \*|5 7 * * *|' "$CONFIG_FILE"
cron refresh >/dev/null 2>&1
check "refresh exits 0" "0" "$?"
check "refresh applies the new schedule" "1" "$(lines '^# schedule: 5 7 \* \* \*$')"
check "refresh keeps it enabled" "1" "$(lines '^DIFFERENZIATA_BOT=1')"
check "refresh keeps other cron jobs" "1" "$(lines 'backup.sh')"
check "refresh does not duplicate the block" "1" "$(lines '>>> differenziata-bot >>>')"

cron stop >/dev/null 2>&1
cron refresh >/dev/null 2>&1
check "refresh preserves the disabled state" "1" "$(lines '^# DIFFERENZIATA_BOT=1')"

# --- invalid input -----------------------------------------------------------
sed -i 's|5 7 \* \* \*|not a schedule|' "$CONFIG_FILE"
cron refresh >/dev/null 2>&1
check "refresh rejects an invalid schedule" "1" "$?"
check "a rejected refresh changes nothing" "1" "$(lines 'backup.sh')"

# --- remove ------------------------------------------------------------------
sed -i 's|not a schedule|0 9 * * *|' "$CONFIG_FILE"
cron remove >/dev/null 2>&1
check "remove exits 0" "0" "$?"
check "remove deletes the block" "0" "$(lines '>>> differenziata-bot >>>')"
check "remove keeps other cron jobs" "1" "$(lines 'backup.sh')"
cron remove >/dev/null 2>&1
check "remove is idempotent" "0" "$?"
cron status >/dev/null 2>&1
check "status exits 2 when not installed" "2" "$?"
cron start >/dev/null 2>&1
check "start fails when not installed" "1" "$?"

# --- re-add ------------------------------------------------------------------
printf 'MAILTO=someone@example.com\n' > "$CRONTAB_FILE"
cron add >/dev/null 2>&1
cron remove >/dev/null 2>&1
cron add >/dev/null 2>&1
check "re-add leaves exactly one block" "1" "$(lines '>>> differenziata-bot >>>')"
check "re-add keeps unrelated crontab lines" "1" "$(lines 'MAILTO=someone@example.com')"

# --- help --------------------------------------------------------------------
check "help exits 0" "0" "$(cron --help >/dev/null 2>&1; echo $?)"
check "no arguments exits 0" "0" "$(cron >/dev/null 2>&1; echo $?)"
check "an unknown verb exits 2" "2" "$(cron frobnicate >/dev/null 2>&1; echo $?)"

printf '\n%s failures\n' "$failures"
[ "$failures" -eq 0 ]