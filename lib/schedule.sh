#!/usr/bin/env bash
#
# lib/schedule.sh — `vminv schedule`: install/manage a cron job that runs the
# metrics scan on a schedule and ships the output to the configured destination.
#
#   vminv schedule add [--profile P] [--cron "EXPR" | --preset N]
#   vminv schedule list
#   vminv schedule remove [--profile P]
#   vminv schedule run --profile P        # what cron invokes: scan + upload
#
# Managed crontab lines are tagged so list/remove only ever touch our entries.
#
# Sourced by vminv; requires lib/common.sh, lib/upload.sh, and cmd_scan (vminv).

# Five commonly-used schedules, shown when no --cron/--preset is given.
CRON_PRESETS=(
  "0 * * * *|hourly (top of every hour)"
  "0 */6 * * *|every 6 hours"
  "0 2 * * *|daily at 02:00"
  "0 1 * * 0|weekly on Sunday 01:00"
  "0 3 1 * *|monthly on the 1st at 03:00"
)

VMINV_ENTRY="${SELF_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}/vminv"
_cron_tag() { printf '# vminv-schedule:%s' "${1:-default}"; }

_print_presets() {
  echo "Choose a schedule:" >&2
  local i=1 line expr desc
  for line in "${CRON_PRESETS[@]}"; do
    expr="${line%%|*}"; desc="${line#*|}"
    printf '  %d) %-16s  %s\n' "$i" "$expr" "$desc" >&2
    i=$((i+1))
  done
  printf '  c) custom 5-field cron expression\n' >&2
}

# Read current user crontab (empty if none).
_crontab_get() { crontab -l 2>/dev/null || true; }

schedule_list() {
  local out; out="$(_crontab_get | grep -F '# vminv-schedule:' || true)"
  if [ -z "$out" ]; then info "No vminv schedules installed."; else
    echo "Installed vminv schedules:"; printf '%s\n' "$out"
  fi
}

schedule_remove() {
  local profile="${1:-}" cur new tag
  command -v crontab >/dev/null 2>&1 || die "crontab not available on this system."
  cur="$(_crontab_get)"
  if [ -n "$profile" ]; then tag="$(_cron_tag "$profile")"; new="$(printf '%s\n' "$cur" | grep -vF "$tag" || true)"
  else new="$(printf '%s\n' "$cur" | grep -vF '# vminv-schedule:' || true)"; fi
  printf '%s\n' "$new" | grep -q . && printf '%s\n' "$new" | crontab - || crontab -r 2>/dev/null || true
  ok "Removed vminv schedule(s)${profile:+ for profile '$profile'}."
}

# schedule_add <profile> <cron-expr-or-empty>
schedule_add() {
  local profile="${1:-default}" cron="${2:-}"
  command -v crontab >/dev/null 2>&1 || die "crontab not available on this system."
  if [ -z "$cron" ]; then
    _print_presets
    local sel; printf 'Selection [3]: ' >&2; IFS= read -r sel || true; [ -z "$sel" ] && sel=3
    if [ "$sel" = "c" ]; then printf 'Cron expression (5 fields): ' >&2; IFS= read -r cron || true
    else
      local idx=$((sel-1))
      [ "$idx" -ge 0 ] && [ "$idx" -lt "${#CRON_PRESETS[@]}" ] || die "Invalid selection."
      cron="${CRON_PRESETS[$idx]%%|*}"
    fi
  fi
  [ -n "$cron" ] || die "No cron expression provided."
  # basic validation: exactly 5 whitespace-separated fields
  [ "$(printf '%s\n' "$cron" | awk '{print NF}')" -eq 5 ] || die "Cron expression must have 5 fields: '${cron}'"

  local logdir="$(vminv_config_home)/logs"; mkdir -p "$logdir"
  local line tag
  tag="$(_cron_tag "$profile")"
  line="${cron} ${VMINV_ENTRY} schedule run --profile ${profile} >> ${logdir}/${profile}.log 2>&1 ${tag}"

  # replace any existing entry for this profile, then install
  local cur new
  cur="$(_crontab_get)"
  new="$(printf '%s\n' "$cur" | grep -vF "$tag" || true)"
  { [ -n "$new" ] && printf '%s\n' "$new"; printf '%s\n' "$line"; } | grep -v '^[[:space:]]*$' | crontab -
  ok "Scheduled '${profile}': ${cron}"
  info "Logs: ${logdir}/${profile}.log"
  schedule_list
}

# schedule_run <profile> : invoked by cron. Runs the scan, then uploads.
# Relies on the caller (vminv main) having already loaded the profile config
# and run cmd_scan, exposing RUN_DIR. Performs the upload step here.
schedule_upload_after_run() {
  if [ -n "${UPLOAD_DEST:-}" ]; then
    phase "Upload"
    upload_run "$RUN_DIR" "$UPLOAD_DEST" || err "Upload to '${UPLOAD_DEST}' failed."
  else
    info "No UPLOAD_DEST configured for this profile; skipping upload."
  fi
}
