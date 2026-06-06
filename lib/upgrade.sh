#!/usr/bin/env bash
#
# lib/upgrade.sh — `vminv upgrade`: self-update from GitHub Releases.
#
# Fetches the latest release of the FIXED upstream repo (below), downloads the
# source tarball, verifies it against the release's checksums.txt when present,
# and installs it over the current installation directory (after backing it up).
#
#   vminv upgrade [--check]
#
# The upgrade source is intentionally NOT user-overridable.
#
# Sourced by vminv; requires lib/common.sh.

# Fixed upstream — not overridable via flag, env, or profile.
readonly VMINV_UPGRADE_REPO="ivasik-k7/vminv"

VMINV_INSTALL_DIR="${SELF_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"

_gh_api() { # _gh_api <path> -> JSON on stdout
  local url="https://api.github.com/$1"
  if command -v curl >/dev/null 2>&1; then curl -fsSL -H "Accept: application/vnd.github+json" "$url"
  elif command -v wget >/dev/null 2>&1; then wget -qO- --header="Accept: application/vnd.github+json" "$url"
  else die "Need curl or wget to contact GitHub."; fi
}

# echo the latest release tag, or empty.
_latest_tag() { # _latest_tag <owner/repo>
  _gh_api "repos/$1/releases/latest" 2>/dev/null | "$JQ_BIN" -r '.tag_name // empty' 2>/dev/null
}

cmd_upgrade() {
  local repo="$VMINV_UPGRADE_REPO" check=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --check) check=1 ;;
      --repo|--repo=*) usage_error "the upgrade source is fixed (${VMINV_UPGRADE_REPO}); --repo is not supported" ;;
      *) usage_error "upgrade: unknown argument '$1'" ;;
    esac
    shift
  done
  info "Current version: ${VMINV_VERSION}. Checking ${repo} for the latest release ..."
  local tag; tag="$(_latest_tag "$repo")"
  [ -n "$tag" ] || die "Could not determine the latest release of ${repo} (no releases, or network/API error)."
  ok "Latest release: ${tag}"
  if [ "$check" -eq 1 ]; then
    info "(--check) Not installing. Run 'vminv upgrade' to apply ${tag}."
    return 0
  fi

  local tmp; tmp="$(mktemp -d)"
  local tarball="${tmp}/src.tar.gz"
  local url="https://github.com/${repo}/archive/refs/tags/${tag}.tar.gz"
  info "Downloading ${url} ..."
  if command -v curl >/dev/null 2>&1; then curl -fsSL -o "$tarball" "$url"
  else wget -qO "$tarball" "$url"; fi
  [ -s "$tarball" ] || { rm -rf "$tmp"; die "Download failed or empty: ${url}"; }

  # Best-effort checksum verification against a release asset 'checksums.txt'.
  local sums; sums="$(_gh_api "repos/${repo}/releases/tags/${tag}" 2>/dev/null \
    | "$JQ_BIN" -r '.assets[]?|select(.name=="checksums.txt")|.browser_download_url' 2>/dev/null)"
  if [ -n "$sums" ]; then
    local want got
    want="$( { command -v curl >/dev/null 2>&1 && curl -fsSL "$sums" || wget -qO- "$sums"; } 2>/dev/null \
             | awk '/(src|source|\.tar\.gz)/{print $1; exit}')"
    if [ -n "$want" ]; then
      got="$(sha256_of_file "$tarball")"
      if [ "$want" = "$got" ]; then ok "Checksum verified."
      else rm -rf "$tmp"; die "Checksum mismatch for ${tag} (expected ${want}, got ${got}). Aborting."; fi
    fi
  else
    warn "No checksums.txt asset on the release — proceeding without checksum verification."
  fi

  tar -xzf "$tarball" -C "$tmp" || { rm -rf "$tmp"; die "Failed to extract release tarball."; }
  local srcdir; srcdir="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d ! -name 'src*' | head -1)"
  [ -d "$srcdir" ] || srcdir="$(find "$tmp" -maxdepth 1 -type d -name "*-*" | head -1)"
  [ -d "$srcdir" ] || { rm -rf "$tmp"; die "Could not locate extracted source directory."; }

  # Back up current install, then sync new files in (preserve bin/, output/, .env, profiles).
  local backup="${VMINV_INSTALL_DIR}.bak.$(date -u +%Y%m%d%H%M%S)"
  info "Backing up current install to ${backup}"
  cp -a "$VMINV_INSTALL_DIR" "$backup" || { rm -rf "$tmp"; die "Backup failed; aborting upgrade."; }

  # Copy code, leaving runtime/data dirs intact.
  local item
  for item in vminv setup.sh setup.ps1 README.md lib matrices powershell tests share config.example.env checksums.txt VERSION; do
    [ -e "${srcdir}/${item}" ] && cp -a "${srcdir}/${item}" "${VMINV_INSTALL_DIR}/"
  done
  # Stamp VERSION with the installed tag so `vminv version` is correct even if the
  # source archive's committed VERSION lagged the release.
  printf '%s\n' "${tag#v}" >"${VMINV_INSTALL_DIR}/VERSION"
  chmod +x "${VMINV_INSTALL_DIR}/vminv" "${VMINV_INSTALL_DIR}/setup.sh" 2>/dev/null || true
  rm -rf "$tmp"
  ok "Upgraded to ${tag}. Backup at ${backup}."
  info "Run 'vminv version' to confirm. Remove the backup once you're happy."
}
