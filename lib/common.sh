#!/usr/bin/env bash
#
# lib/common.sh — shared foundation for vminv.
#
#   * configuration loading (.env + env override)
#   * logging with secret redaction
#   * the READ-ONLY govc wrapper (the core safety control)
#   * small CSV/JSON helpers
#
# This file is sourced, never executed directly.

# --- Resolve paths ----------------------------------------------------------
# ROOT_DIR is the project root (parent of lib/).
LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
ROOT_DIR="$(cd -- "${LIB_DIR}/.." >/dev/null 2>&1 && pwd -P)"
BIN_DIR="${ROOT_DIR}/bin"
GOVC_BIN="${GOVC_BIN:-${BIN_DIR}/govc}"
JQ_BIN="${JQ_BIN:-${BIN_DIR}/jq}"

# --- Runtime preflight ------------------------------------------------------
# vminv uses associative arrays and `${arr[@]+...}` guards that require bash 4+.
# Fail fast with a clear message rather than a cryptic syntax error on old bash
# (notably macOS's stock /bin/bash 3.2 — install a newer bash via Homebrew).
require_bash() {
  if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "vminv requires bash 4.0+ (found ${BASH_VERSION:-unknown})." >&2
    echo "  macOS: 'brew install bash' then run with that bash." >&2
    exit 1
  fi
}

# Full preflight for the scan path (needs the vendored tools).
require_runtime() {
  require_bash
  local missing=""
  [ -x "$GOVC_BIN" ] || missing="${missing} govc"
  [ -x "$JQ_BIN" ]   || missing="${missing} jq"
  if [ -n "$missing" ]; then
    echo "Missing required tool(s):${missing}. Run ./setup.sh first." >&2
    exit 1
  fi
}

# --- Exit codes (documented in --help / README) -----------------------------
readonly EX_OK=0 EX_ERR=1 EX_USAGE=2 EX_CONN=3 EX_PARTIAL=4 EX_INTERRUPT=130
# Set when a non-fatal collector fails; makes `scan` exit EX_PARTIAL.
VMINV_PARTIAL=0
mark_partial() { VMINV_PARTIAL=1; }

# --- Output controls --------------------------------------------------------
# Verbosity: 0=quiet (errors only) · 1=normal · 2=verbose (debug to stderr).
VMINV_VERBOSITY=1
VMINV_NO_COLOR=0       # set by --no-color
VMINV_NO_PROGRESS=0    # set by --no-progress

# (Re)compute color codes. Color is OFF when: --no-color, $NO_COLOR is set, or
# stderr is not a TTY. Call again after parsing flags.
setup_colors() {
  if [ "$VMINV_NO_COLOR" -eq 0 ] && [ -z "${NO_COLOR:-}" ] && [ -t 2 ]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
    C_BLU=$'\033[34m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_RST=$'\033[0m'
  else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_DIM=""; C_BOLD=""; C_RST=""
  fi
}
setup_colors

# --- Temp-dir registry (cleaned by the EXIT/INT/TERM trap in vminv) ----------
VMINV_TMPDIRS=()
register_tmp() { [ -n "${1:-}" ] && VMINV_TMPDIRS+=("$1"); return 0; }
cleanup_tmpdirs() {
  local d
  for d in ${VMINV_TMPDIRS[@]+"${VMINV_TMPDIRS[@]}"}; do [ -n "$d" ] && rm -rf "$d" 2>/dev/null; done
  return 0
}

# --- Secret redaction -------------------------------------------------------
# Any string registered here is scrubbed from ALL log/console output.
REDACT_VALUES=()
redact_register() { [ -n "${1:-}" ] && REDACT_VALUES+=("$1"); return 0; }

redact() { # redact <string> -> scrubbed string
  local s="$1" v
  # Guard the expansion: an empty array under `set -u` is an error on bash<4.4.
  for v in ${REDACT_VALUES[@]+"${REDACT_VALUES[@]}"}; do
    [ -n "$v" ] && s="${s//"$v"/***REDACTED***}"
  done
  printf '%s' "$s"
}

# Filter a stream (e.g. captured govc stderr) through redaction.
redact_stream() { local line; while IFS= read -r line; do redact "$line"; printf '\n'; done; }

# --- Logging ----------------------------------------------------------------
# RUN_LOG="" means console-only (used by --dry-run). Otherwise lines are also
# appended to the run log file. Everything passes through redaction.
RUN_LOG=""
_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

_logfile() { # _logfile <level> <message>
  [ -n "$RUN_LOG" ] || return 0
  printf '%s [%s] %s\n' "$(_ts)" "$1" "$(redact "$2")" >>"$RUN_LOG"
}

# Human output goes to stderr; stdout is reserved for machine data. info/ok/phase
# are suppressed in quiet mode (verbosity 0); dbg also echoes in verbose mode (2).
info() { [ "$VMINV_VERBOSITY" -ge 1 ] && { local m; m="$(redact "$*")"; printf '%s[*]%s %s\n' "$C_BLU" "$C_RST" "$m" >&2; }; _logfile INFO "$*"; return 0; }
ok()   { [ "$VMINV_VERBOSITY" -ge 1 ] && { local m; m="$(redact "$*")"; printf '%s[+]%s %s\n' "$C_GRN" "$C_RST" "$m" >&2; }; _logfile INFO "$*"; return 0; }
warn() { local m; m="$(redact "$*")"; printf '%s[!]%s %s\n' "$C_YEL" "$C_RST" "$m" >&2; _logfile WARN "$*"; return 0; }
err()  { local m; m="$(redact "$*")"; printf '%svminv:%s %s\n' "$C_RED" "$C_RST" "$m" >&2; _logfile ERROR "$*"; return 0; }
# die [exit-code] <message...> : print error, exit (default EX_ERR=1).
die()  { local code=1; if [[ "${1:-}" =~ ^[0-9]+$ ]]; then code="$1"; shift; fi; err "$*"; exit "$code"; }
# usage_error <message> : usage problem -> short hint + exit EX_USAGE (2).
usage_error() { err "$*"; printf 'Run '\''vminv help'\'' or '\''vminv <command> --help'\''.\n' >&2; exit "$EX_USAGE"; }
# debug: always to log file; to stderr only when verbose.
dbg()  { [ "$VMINV_VERBOSITY" -ge 2 ] && { local m; m="$(redact "$*")"; printf '%s[d]%s %s\n' "$C_DIM" "$C_RST" "$m" >&2; }; _logfile DEBUG "$*"; return 0; }
# phase marks a major section; progress shows transient status during long work.
phase()    { [ "$VMINV_VERBOSITY" -ge 1 ] && { local m; m="$(redact "$*")"; printf '\n%s== %s ==%s\n' "$C_BOLD" "$m" "$C_RST" >&2; }; _logfile INFO "== $* =="; return 0; }
progress() { [ "$VMINV_NO_PROGRESS" -eq 0 ] && [ "$VMINV_VERBOSITY" -ge 1 ] && [ -t 2 ] && printf '%s    ... %s%s\r' "$C_DIM" "$(redact "$*")" "$C_RST" >&2; return 0; }

# --- Configuration ----------------------------------------------------------
# Known config keys (also the set whose pre-existing env values override .env).
CONFIG_KEYS=(
  VCENTER_HOST VCENTER_USER VCENTER_PASSWORD VCENTER_INSECURE
  SCOPE_DATACENTER SCOPE_CLUSTER SCOPE_FOLDER SCOPE_VM_GLOB
  PERF_WINDOW_DAYS PERF_INTERVAL
  THRESHOLD_LARGE_DISK_GB THRESHOLD_LARGE_VM_GB
  THRESHOLD_OLD_HW_VERSION THRESHOLD_SNAPSHOT_AGE_DAYS
  TARGET_PROVIDER OUTPUT_DIR
  UPLOAD_DEST VMINV_REPO
)

# --- Config home & named profiles (aws-cli-style) ---------------------------
# Non-secret per-environment config lives in ~/.config/vminv/profiles/<name>.env
# (created by `vminv configure`). Secrets are NOT stored there by default.
vminv_config_home() { printf '%s/vminv' "${XDG_CONFIG_HOME:-${HOME}/.config}"; }
vminv_profiles_dir() { printf '%s/profiles' "$(vminv_config_home)"; }
vminv_profile_file() { printf '%s/%s.env' "$(vminv_profiles_dir)" "${1:-default}"; }

# Defaults applied when neither env nor .env provide a value.
config_defaults() {
  : "${VCENTER_INSECURE:=false}"
  : "${PERF_WINDOW_DAYS:=30}"
  : "${PERF_INTERVAL:=daily}"
  : "${THRESHOLD_LARGE_DISK_GB:=2048}"
  : "${THRESHOLD_LARGE_VM_GB:=8192}"
  : "${THRESHOLD_OLD_HW_VERSION:=9}"
  : "${THRESHOLD_SNAPSHOT_AGE_DAYS:=7}"
  : "${TARGET_PROVIDER:=aws}"
  : "${OUTPUT_DIR:=${ROOT_DIR}/output}"
}

# load_config <env-file> : source the file, but let pre-existing environment
# variables WIN over file values (env > file). CLI flags are applied later by
# the caller (CLI > env > file).
load_config() {
  local env_file="$1" k
  declare -gA __ENV_OVERRIDE=()
  for k in "${CONFIG_KEYS[@]}"; do
    [ -n "${!k+x}" ] && __ENV_OVERRIDE["$k"]="${!k}"
  done
  if [ -f "$env_file" ]; then
    # shellcheck disable=SC1090
    set -a; source "$env_file"; set +a
    dbg "Loaded config from ${env_file}"
  else
    warn "Config file not found: ${env_file} (relying on environment + defaults)"
  fi
  for k in "${!__ENV_OVERRIDE[@]}"; do
    printf -v "$k" '%s' "${__ENV_OVERRIDE[$k]}"
  done
  config_defaults
}

# --- govc connection environment --------------------------------------------
# Sets the GOVC_* variables govc reads. The URL carries NO credentials; the
# username/password are passed via dedicated env vars so they never appear in
# any URL that might be echoed in an error.
setup_govc_env() {
  export GOVC_URL="https://${VCENTER_HOST}/sdk"
  export GOVC_USERNAME="${VCENTER_USER}"
  export GOVC_PASSWORD="${VCENTER_PASSWORD:-}"
  if [ "${VCENTER_INSECURE}" = "true" ]; then
    export GOVC_INSECURE=1
    warn "VCENTER_INSECURE=true — TLS certificate verification is DISABLED."
    warn "  Self-signed/untrusted certs will be accepted. Prefer importing the CA."
  else
    export GOVC_INSECURE=0
  fi
  # Never persist datacenter into env implicitly; scope is passed explicitly.
}

# ============================================================================
# READ-ONLY govc wrapper  —  the central enforcement of the safety guarantee.
# ============================================================================
#
# Only verbs on this allowlist may run. Everything else is refused before
# execution. This is an allowlist (deny-by-default), so a new mutating verb
# cannot slip in by omission — it simply won't be permitted.
GOVC_RO_ALLOW=(
  about version env
  ls find
  object.collect
  datacenter.info
  host.info
  datastore.info datastore.cluster.info
  vm.info
  pool.info
  dvs.portgroup.info
  metric.ls metric.info metric.sample
  tags.ls tags.category.ls tags.attached.ls
  license.ls license.assigned.ls
  permissions.ls
  fields.ls
)

_govc_verb_allowed() { # _govc_verb_allowed <verb>
  local v
  for v in "${GOVC_RO_ALLOW[@]}"; do [ "$v" = "$1" ] && return 0; done
  return 1
}

# govc_ro <verb> [args...] : run a single read-only govc command.
# Refuses any verb not on the allowlist. This is the ONLY place the govc
# binary is invoked, so the guarantee is enforced in exactly one chokepoint.
govc_ro() {
  local verb="${1:-}"; shift || true
  if ! _govc_verb_allowed "$verb"; then
    die "REFUSED non-read-only govc verb: '${verb}'. vminv is strictly read-only."
  fi
  [ -x "$GOVC_BIN" ] || die "govc not found at ${GOVC_BIN} (run ./setup.sh)"
  dbg "govc ${verb} $*"
  "$GOVC_BIN" "$verb" "$@"
}

# govc_query <name> <verb> [args...] : a named read-only query.
# In live mode it runs govc_ro. In fixture mode (VMINV_FIXTURES set) it returns
# the canned JSON at $VMINV_FIXTURES/<name>.json instead — enabling fully
# offline development and unit testing with NO live vCenter. The verb is still
# validated against the allowlist in both modes, so tests exercise the guard.
govc_query() {
  local name="$1" verb="$2"; shift 2
  if ! _govc_verb_allowed "$verb"; then
    die "REFUSED non-read-only govc verb: '${verb}'. vminv is strictly read-only."
  fi
  if [ -n "${VMINV_FIXTURES:-}" ]; then
    local f="${VMINV_FIXTURES}/${name}.json"
    [ -f "$f" ] || die "Fixture not found: ${f}"
    dbg "fixture ${name} (${verb})"
    cat "$f"
    return 0
  fi
  govc_ro "$verb" "$@"
}

# --- Property-collector helpers ---------------------------------------------
# A reusable jq prelude for parsing `govc object.collect -json` output (an array
# of ObjectContent: {obj:{type,value}, propSet:[{name,val}]}).
#   p($o;$n)   -> value of property $n on object $o (or null)
#   gib($b)    -> bytes -> GiB rounded to 2 dp
#   mib($b)    -> bytes -> MiB rounded to 0 dp
#   age_days($iso;$now) -> whole days between an ISO-8601 timestamp and $now
#                          (epoch seconds). Tolerates fractional seconds and a
#                          trailing Z. Returns null on unparseable/empty input.
JQ_OC_HELPERS='
  def p($o; $n): ($o.propSet[]? | select(.name==$n) | .val);
  def gib($b): (((($b // 0) | tonumber) / 1073741824) * 100 | floor) / 100;
  def mib($b): ((($b // 0) | tonumber) / 1048576 | floor);
  def kib_to_gib($k): ((($k // 0) | tonumber) / 1048576 * 100 | floor) / 100;
  def age_days($iso; $now):
    if ($iso // "") == "" then null
    else ( ($iso | sub("\\.[0-9]+"; "") | sub("Z$"; "") + "Z" | fromdateiso8601) as $t
           | (($now - $t) / 86400 | floor) ) // null
    end;
'

# now_epoch : current time in epoch seconds (portable: GNU and BSD date).
now_epoch() { date -u +%s; }

# resolve_version : industry-standard git-describe versioning.
#   * exact/after a tag   -> 1.2.3  or  1.2.3-5-g<hash>[-dirty]   (tags are vX.Y.Z)
#   * git checkout, no tag -> <VERSION>-<shorthash>[-dirty]       (e.g. 0.1.0-g1a2b3c4)
#   * no git (installed/release tarball) -> contents of the VERSION file
# The VERSION file is the release baseline (bumped + tagged together at release).
resolve_version() {
  local base; base="$(cat "${ROOT_DIR}/VERSION" 2>/dev/null || echo 0.1.0)"
  if command -v git >/dev/null 2>&1 && git -C "$ROOT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    local desc; desc="$(git -C "$ROOT_DIR" describe --tags --dirty --always 2>/dev/null || true)"
    case "$desc" in
      v[0-9]*) printf '%s' "${desc#v}"; return ;;     # on/after a vX.Y.Z tag
      ?*)      printf '%s-g%s' "$base" "${desc#g}"; return ;;  # no tags yet: base-g<hash>
    esac
  fi
  printf '%s' "$base"
}

# Tool presence/version helpers (kept here so the govc binary is referenced only
# within common.sh — the read-only chokepoint; see tests/test_readonly.sh).
govc_present() { [ -x "$GOVC_BIN" ]; }
jq_present()   { [ -x "$JQ_BIN" ]; }
govc_version_str() { govc_present && "$GOVC_BIN" version 2>/dev/null | awk '{print $2}'; }
jq_version_str()   { jq_present && "$JQ_BIN" --version 2>/dev/null; }

# sha256_of_file <file> -> hex digest (sha256sum or shasum).
sha256_of_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else die "Need sha256sum or shasum."; fi
}

# infra_scope_root : inventory path to start infrastructure collection from.
# Folder scope does not apply to infra objects; datacenter scope does.
infra_scope_root() {
  if [ -n "${SCOPE_DATACENTER:-}" ]; then printf '/%s' "$SCOPE_DATACENTER"; else printf '/'; fi
}

# oc_query <fixture-name> <govc-kind> [props...] : run a typed property-collector
# query from the infra scope root (or read the named fixture in offline mode).
oc_query() {
  local name="$1" kind="$2"; shift 2
  govc_query "$name" object.collect -json -type "$kind" "$(infra_scope_root)" "$@"
}

# --- JSON / CSV helpers ------------------------------------------------------
jq_ro() { "$JQ_BIN" "$@"; }

# json_to_csv <comma-separated-keys> : reads a JSON array of flat objects on
# stdin, writes CSV (header + rows) using the given ordered key list.
# Missing keys and JSON null render as empty cells. Boolean false is preserved
# as "false" (do NOT use jq's `//`, which treats false as empty).
json_to_csv() {
  local keys="$1"
  "$JQ_BIN" -r --arg keys "$keys" '
    ($keys | split(",")) as $k
    | ($k | @csv),
      ( .[]
        | . as $row
        | [ $k[] as $key | $row[$key] | if . == null then "" else . end ]
        | @csv )
  '
}

# csv_to_json : read a SIMPLE CSV (header row, no quoted/embedded commas) on
# stdin -> JSON array of objects. Blank lines and '#'-comment lines are skipped.
# Intended for the editable matrices/ files (controlled, comma-free values).
csv_to_json() {
  "$JQ_BIN" -R -s '
    (split("\n") | map(select((length > 0) and (startswith("#") | not)))) as $lines
    | if ($lines | length) < 1 then []
      else ($lines[0] | split(",")) as $h
        | $lines[1:]
        | map( split(",") as $r
               | reduce range(0; ($h | length)) as $i ({}; .[$h[$i]] = (($r[$i]) // "")) )
      end'
}

# csv_count_rows <file> : data rows (excludes header). 0 if file absent/empty.
csv_count_rows() {
  local f="$1"
  [ -f "$f" ] || { echo 0; return; }
  local n; n=$(wc -l <"$f"); n=$((n > 0 ? n - 1 : 0)); echo "$n"
}
