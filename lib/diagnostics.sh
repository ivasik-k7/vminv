#!/usr/bin/env bash
#
# lib/diagnostics.sh — visibility commands: `config` and `doctor`.
# These print to STDOUT (the user asked for this data), secrets always redacted.
#
# Sourced by vminv; requires lib/common.sh and a loaded config.

# Is a value present and not the shipped placeholder?
_is_real() { [ -n "${1:-}" ] && [ "${1:-}" != "vcenter.example.com" ]; }

# Resolve where the password will come from at run time (no secrets printed).
credential_status() {
  if [ -n "${VCENTER_PASSWORD:-}" ]; then echo "set via \$VCENTER_PASSWORD (environment)"; return; fi
  if [ "${PASSWORD_SOURCE:-prompt}" = "keyring" ] && [ -n "${PROFILE:-}" ]; then
    if keyring_get "$PROFILE" >/dev/null 2>&1; then echo "stored in OS keyring (profile '${PROFILE}')"; return; fi
    echo "keyring selected but no secret found — will prompt"; return
  fi
  if [ -t 0 ]; then echo "will prompt interactively at run time"; else echo "NONE — set \$VCENTER_PASSWORD (no TTY to prompt)"; fi
}

# Print the effective, resolved configuration (CLI > env > profile/.env > default).
cmd_config() {
  local src="${RESOLVED_CONFIG_FILE:-(defaults)}"
  printf '%s%sEffective configuration%s\n' "$C_BOLD" "" "$C_RST"
  printf '  %-22s %s\n' "profile"        "${PROFILE:-(none / .env)}"
  printf '  %-22s %s\n' "config file"    "$src"
  printf '  %-22s %s\n' "VCENTER_HOST"   "$(_is_real "${VCENTER_HOST:-}" && echo "${VCENTER_HOST}" || echo "${C_YEL}${VCENTER_HOST:-<unset>} (placeholder/unset)${C_RST}")"
  printf '  %-22s %s\n' "VCENTER_USER"   "${VCENTER_USER:-<unset>}"
  printf '  %-22s %s\n' "credentials"    "$(credential_status)"
  printf '  %-22s %s\n' "VCENTER_INSECURE" "${VCENTER_INSECURE:-false}"
  printf '  %-22s %s\n' "TARGET_PROVIDER" "${TARGET_PROVIDER:-aws}"
  printf '  %-22s %s\n' "scope dc/cluster" "${SCOPE_DATACENTER:-*} / ${SCOPE_CLUSTER:-*}"
  printf '  %-22s %s\n' "scope folder/vm"  "${SCOPE_FOLDER:-*} / ${SCOPE_VM_GLOB:-*}"
  printf '  %-22s %s\n' "PERF_WINDOW_DAYS" "${PERF_WINDOW_DAYS:-30} (${PERF_INTERVAL:-daily})"
  printf '  %-22s %s\n' "OUTPUT_DIR"     "${OUTPUT_DIR:-./output}"
  printf '  %-22s %s\n' "UPLOAD_DEST"    "${UPLOAD_DEST:-<none>}"
  printf '  %-22s %s\n' "VMINV_REPO"     "${VMINV_REPO:-<none>}"
  printf '\n(Password is never displayed or stored in the profile.)\n'
}

# Diagnostics + readiness verdict + next steps.
cmd_doctor() {
  local ok_mark="${C_GRN}ok${C_RST}" bad="${C_RED}--${C_RST}" warn="${C_YEL}!!${C_RST}"
  printf '%s================ vminv doctor ================%s\n' "$C_BOLD" "$C_RST"

  printf '%sRuntime%s\n' "$C_BOLD" "$C_RST"
  printf '  [%s] bash %s\n' "$ok_mark" "${BASH_VERSION}"
  if govc_present; then printf '  [%s] govc %s\n' "$ok_mark" "$(govc_version_str)"; else printf '  [%s] govc missing — run ./setup.sh\n' "$bad"; fi
  if jq_present;   then printf '  [%s] jq %s\n' "$ok_mark" "$(jq_version_str)"; else printf '  [%s] jq missing — run ./setup.sh\n' "$bad"; fi
  if command -v vminv >/dev/null 2>&1; then printf '  [%s] cli on PATH: %s\n' "$ok_mark" "$(command -v vminv)"; else printf '  [%s] cli not on PATH (run ./setup.sh)\n' "$warn"; fi

  printf '\n%sProfiles%s\n' "$C_BOLD" "$C_RST"
  local pdir; pdir="$(vminv_profiles_dir)"
  if [ -d "$pdir" ] && ls "$pdir"/*.env >/dev/null 2>&1; then
    local n; n="$(ls "$pdir"/*.env 2>/dev/null | wc -l | tr -d ' ')"
    printf '  [%s] %s profile(s) in %s\n' "$ok_mark" "$n" "$pdir"
    profile_list 2>/dev/null | sed 's/^/      /'
  else
    printf '  [%s] no profiles yet — run: vminv configure\n' "$warn"
  fi

  printf '\n%sEffective config%s\n' "$C_BOLD" "$C_RST"
  cmd_config | sed 's/^/  /'

  printf '\n%sOutput%s\n' "$C_BOLD" "$C_RST"
  local od="${OUTPUT_DIR:-./output}"
  if mkdir -p "$od" 2>/dev/null && [ -w "$od" ]; then printf '  [%s] writable: %s\n' "$ok_mark" "$od"; else printf '  [%s] NOT writable: %s\n' "$bad" "$od"; fi

  # Readiness verdict
  printf '\n%sReadiness%s\n' "$C_BOLD" "$C_RST"
  local issues=()
  govc_present && jq_present || issues+=("run ./setup.sh to install govc/jq")
  _is_real "${VCENTER_HOST:-}" || issues+=("set VCENTER_HOST (vminv configure)")
  [ -n "${VCENTER_USER:-}" ]   || issues+=("set VCENTER_USER (vminv configure)")
  case "$(credential_status)" in NONE*) issues+=("provide a password: export VCENTER_PASSWORD or use a keyring profile");; esac
  if [ "${#issues[@]}" -eq 0 ]; then
    printf '  %s[+] Ready.%s  Validate connectivity:  vminv%s --dry-run\n' "$C_GRN" "$C_RST" "$( [ -n "${PROFILE:-}" ] && echo " --profile ${PROFILE}" )"
  else
    printf '  %s[!] Not ready:%s\n' "$C_YEL" "$C_RST"
    local i; for i in "${issues[@]}"; do printf '      - %s\n' "$i"; done
    printf '\n  No vCenter yet? See the whole tool work on sample data:  %svminv demo%s\n' "$C_BOLD" "$C_RST"
  fi
  printf '%s=============================================%s\n' "$C_BOLD" "$C_RST"
}
