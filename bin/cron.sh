#!/usr/bin/env bash
# Manage the differenziata-bot crontab entry. Only the block between the markers
# is ever touched, so other cron jobs in the same crontab are left alone.
#
#   cron.sh add      install the entry (fails if already installed)
#   cron.sh remove   delete the entry
#   cron.sh start    enable the entry (uncomment it)
#   cron.sh stop     disable the entry (comment it out)
#   cron.sh status   show installation state, schedule and recent log lines
#   cron.sh refresh  rewrite the entry from config.toml, rotate the log
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
VAR="$ROOT/var"
LOG="$VAR/cron.log"
BEGIN="# >>> differenziata-bot >>>"
END="# <<< differenziata-bot <<<"
SIGNATURE="DIFFERENZIATA_BOT=1"
LOG_MAX_BYTES=$((1024 * 1024))
BACKUP="$VAR/crontab.backup"

usage() {
  sed -n '5,10p' "$0" | sed 's/^# \{0,1\}//'
}

die() {
  echo "cron.sh: $*" >&2
  exit 1
}

read_crontab() {
  if [ -n "${CRONTAB_FILE:-}" ]; then
    [ -f "$CRONTAB_FILE" ] || return 0
    cat -- "$CRONTAB_FILE"
  else
    crontab -l 2>/dev/null || true
  fi
}

write_crontab() {
  if [ -n "${CRONTAB_FILE:-}" ]; then
    cat > "$CRONTAB_FILE"
  else
    crontab -
  fi
}

backup_crontab() {
  mkdir -p "$VAR"
  read_crontab > "$BACKUP" || true
}

# Drops every line from BEGIN to END inclusive, leaves the rest untouched.
strip_block() {
  awk -v b="$BEGIN" -v e="$END" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    skip != 1 { print }
  '
}

config_file() {
  if [ -n "${CONFIG_FILE:-}" ]; then
    printf '%s\n' "$CONFIG_FILE"
  elif [ -f "$ROOT/config.toml" ]; then
    printf '%s\n' "$ROOT/config.toml"
  elif [ -f "$ROOT/config.example.toml" ]; then
    printf '%s\n' "$ROOT/config.example.toml"
  else
    return 1
  fi
}

# Reads cron.schedule from the [cron] table without tripping over other tables.
read_schedule() {
  local file=$1
  [ -f "$file" ] || return 1
  awk '
    /^[[:space:]]*\[/ {
      table = $0
      gsub(/[[:space:]]/, "", table)
      sub(/^\[/, "", table)
      sub(/\]$/, "", table)
    }
    table == "cron" && /^[[:space:]]*schedule[[:space:]]*=/ {
      sub(/^[[:space:]]*schedule[[:space:]]*=[[:space:]]*/, "")
      sub(/[[:space:]]*#.*$/, "")
      gsub(/"/, "")
      gsub(/\047/, "")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      print
      found = 1
      exit
    }
    END { if (!found) exit 1 }
  ' "$file"
}

validate_schedule() {
  local schedule=$1
  [ -n "$schedule" ] || return 1
  case $schedule in
    *$'\n'* | *$'\r'*) return 1 ;;
  esac
  local -a fields
  read -r -a fields <<< "$schedule"
  [ "${#fields[@]}" -eq 5 ] || return 1
  local field
  for field in "${fields[@]}"; do
    [[ $field =~ ^[-*/0-9,?A-Za-z]+$ ]] || return 1
  done
  return 0
}

command_line() {
  printf '%s %s >> %s 2>&1\n' "$SIGNATURE" "$ROOT/bin/differenziata-bot" "$LOG"
}

render_block() {
  local schedule=$1
  printf '%s\n' "$BEGIN"
  printf '# managed by bin/cron.sh - edit config.toml then run: bin/cron.sh refresh\n'
  command_line | sed "s|^|# schedule: ${schedule}\n|"
  printf '%s\n' "$END"
}

# Reads the whole crontab into a temp file first. When CRONTAB_FILE is in use,
# writing truncates that same file, so a streaming read/write pipeline would
# destroy every other cron job.
read_crontab_to() {
  read_crontab > "$1"
}

install_block() {
  local schedule=$1
  mkdir -p "$VAR"
  local existing
  existing=$(mktemp)
  read_crontab_to "$existing"
  local tmp
  tmp=$(mktemp)
  strip_block < "$existing" > "$tmp"
  { cat "$tmp"; echo; render_block "$schedule"; } | write_crontab
  rm -f "$tmp" "$existing"
}

is_installed() {
  read_crontab | grep -qF "$BEGIN"
}

is_enabled() {
  read_crontab | grep -F "$SIGNATURE" | grep -qv '^[[:space:]]*#'
}

set_enabled() {
  local enabled=$1
  local tmp
  tmp=$(mktemp)
  read_crontab | awk -v b="$BEGIN" -v e="$END" -v sig="$SIGNATURE" -v on="$enabled" '
    $0 == b { inblock = 1; print; next }
    $0 == e { inblock = 0; print; next }
    inblock == 1 && index($0, sig) {
      line = $0
      sub(/^[[:space:]]*#+[[:space:]]*/, "", line)
      sub(/^[[:space:]]*/, "", line)
      if (on == "enabled") print line
      else print "# " line
      next
    }
    { print }
  ' > "$tmp"
  write_crontab < "$tmp"
  rm -f "$tmp"
}

rotate_log() {
  [ -f "$LOG" ] || return 0
  local size
  size=$(wc -c < "$LOG")
  if [ "$size" -gt "$LOG_MAX_BYTES" ]; then
    mv -f -- "$LOG" "$LOG.1"
    echo "cron.sh: rotated $LOG to $LOG.1"
  fi
}

cmd_add() {
  if is_installed; then
    die "already installed; use 'cron.sh refresh' to update it or 'cron.sh remove' first"
  fi
  local schedule
  schedule=$(read_schedule "$(config_file)") || die "no cron.schedule found in $(config_file)"
  validate_schedule "$schedule" || die "cron.schedule is not a valid 5-field cron expression: $schedule"
  backup_crontab
  install_block "$schedule"
  echo "cron.sh: installed '$schedule' (backup: $BACKUP)"
}

cmd_remove() {
  if ! is_installed; then
    echo "cron.sh: not installed, nothing to remove"
    return 0
  fi
  backup_crontab
  local existing tmp
  existing=$(mktemp)
  tmp=$(mktemp)
  read_crontab_to "$existing"
  strip_block < "$existing" > "$tmp"
  write_crontab < "$tmp"
  rm -f "$tmp" "$existing"
  echo "cron.sh: removed"
}

cmd_start() {
  is_installed || die "not installed; run 'cron.sh add' first"
  backup_crontab
  set_enabled enabled
  echo "cron.sh: started"
}

cmd_stop() {
  is_installed || die "not installed; nothing to stop"
  backup_crontab
  set_enabled disabled
  echo "cron.sh: stopped"
}

cmd_refresh() {
  local schedule
  schedule=$(read_schedule "$(config_file)") || die "no cron.schedule found in $(config_file)"
  validate_schedule "$schedule" || die "cron.schedule is not a valid 5-field cron expression: $schedule"
  # install_block rewrites the block enabled, so remember whether the job was
  # stopped and restore that afterwards: refreshing must not re-enable a job the
  # user deliberately paused.
  local was_enabled=false
  if is_installed && is_enabled; then
    was_enabled=true
  fi
  backup_crontab
  install_block "$schedule"
  if ! $was_enabled; then
    set_enabled disabled
  fi
  rotate_log
  echo "cron.sh: refreshed to '$schedule'${was_enabled:+ (enabled)}${was_enabled:-(disabled)}"
}

cmd_status() {
  local file config
  file=$(config_file || true)
  config=$(read_schedule "$file" 2>/dev/null || echo "unavailable")
  if is_installed; then
    local state
    if is_enabled; then state="enabled"; else state="disabled"; fi
    printf 'installed : yes (%s)\n' "$state"
    printf 'schedule  : %s\n' "$config"
    printf 'command   : %s\n' "$(command_line)"
    printf 'log       : %s\n' "$LOG"
    echo "--- last 10 log lines ---"
    if [ -f "$LOG" ]; then
      tail -n 10 "$LOG"
    else
      echo "(no log yet)"
    fi
    [ "$state" = "enabled" ] && return 0
    return 1
  fi
  echo "installed : no"
  printf 'schedule  : %s\n' "$config"
  printf 'log       : %s\n' "$LOG"
  return 2
}

main() {
  case ${1:-} in
    add) cmd_add ;;
    remove) cmd_remove ;;
    start) cmd_start ;;
    stop) cmd_stop ;;
    status) cmd_status ;;
    refresh) cmd_refresh ;;
    "" | -h | --help | help) usage; exit 0 ;;
    *)
      echo "cron.sh: unknown command '$1'" >&2
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"