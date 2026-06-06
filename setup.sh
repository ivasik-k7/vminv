#!/usr/bin/env bash
#
# setup.sh — prepare a machine to run vminv (read-only VMware inventory tool).
#
# What it does (idempotent, safe to re-run):
#   1. Detects OS / architecture.
#   2. Downloads PINNED versions of govc and jq into ./bin (no root needed).
#   3. Verifies each download's SHA-256 against ./checksums.txt
#      (trust-on-first-use pin on first download; strict thereafter).
#   4. Scaffolds .env from config.example.env if missing.
#   5. Prints a readiness summary.
#
# It NEVER touches a vCenter. It only fetches tooling and lays down config.
#
# Usage:
#   ./setup.sh                # detect, install missing tools, scaffold config
#   ./setup.sh --force        # re-download even if binaries already present
#   ./setup.sh --offline      # skip downloads; only check what's present
#   ./setup.sh -h | --help
#
set -euo pipefail

# --- Pinned versions --------------------------------------------------------
# Bump these to upgrade. After bumping, the first run will TOFU-pin the new
# checksums into checksums.txt (review + commit them).
GOVC_VERSION="v0.37.3"
JQ_VERSION="1.7.1"

# --- Paths ------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
BIN_DIR="${SCRIPT_DIR}/bin"
CHECKSUMS_FILE="${SCRIPT_DIR}/checksums.txt"
ENV_EXAMPLE="${SCRIPT_DIR}/config.example.env"
ENV_FILE="${SCRIPT_DIR}/.env"

# --- Flags ------------------------------------------------------------------
FORCE=0
OFFLINE=0
INSTALL_CLI=1     # symlink `vminv` onto PATH (auto: user-local, sudo fallback)
INSTALL_SCOPE=""  # "", "user", or "system"

# --- Pretty output ----------------------------------------------------------
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_BOLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BOLD=""; C_RST=""
fi
info()  { printf '%s[*]%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()    { printf '%s[+]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
err()   { printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
die()   { err "$*"; exit 1; }

usage() { sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0; }

# --- Parse args -------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --force)   FORCE=1 ;;
    --offline) OFFLINE=1 ;;
    --no-cli)  INSTALL_CLI=0 ;;
    --system)  INSTALL_SCOPE="system" ;;
    --user)    INSTALL_SCOPE="user" ;;
    -h|--help) usage ;;
    *) die "Unknown argument: $1 (try --help)" ;;
  esac
  shift
done

# --- OS / arch detection ----------------------------------------------------
detect_platform() {
  local uname_s uname_m
  uname_s="$(uname -s)"
  uname_m="$(uname -m)"

  case "$uname_s" in
    Linux)  OS="Linux";  GOVC_OS="Linux";  JQ_OS="linux" ;;
    Darwin) OS="Darwin"; GOVC_OS="Darwin"; JQ_OS="macos" ;;
    *) die "Unsupported OS: $uname_s (this is the bash path; use setup.ps1 on Windows)" ;;
  esac

  case "$uname_m" in
    x86_64|amd64) ARCH="x86_64"; GOVC_ARCH="x86_64"; JQ_ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64"; GOVC_ARCH="arm64";  JQ_ARCH="arm64" ;;
    *) die "Unsupported architecture: $uname_m" ;;
  esac

  # WSL note (still Linux, but worth surfacing for the user).
  if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
    PLATFORM_NOTE=" (WSL detected)"
  else
    PLATFORM_NOTE=""
  fi
  info "Platform: ${OS}/${ARCH}${PLATFORM_NOTE}"
}

# --- Download helper (curl or wget) -----------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

fetch() { # fetch <url> <dest>
  local url="$1" dest="$2"
  if have curl; then
    curl -fsSL --retry 3 --retry-delay 2 -o "$dest" "$url"
  elif have wget; then
    wget -q -O "$dest" "$url"
  else
    die "Need curl or wget to download tools (neither found)."
  fi
}

# --- SHA-256 helper (sha256sum or shasum) -----------------------------------
sha256_of() { # sha256_of <file> -> prints hex digest
  local f="$1"
  if have sha256sum; then
    sha256sum "$f" | awk '{print $1}'
  elif have shasum; then
    shasum -a 256 "$f" | awk '{print $1}'
  else
    die "Need sha256sum or shasum to verify downloads."
  fi
}

# Look up a pinned checksum for an asset filename; prints digest or empty.
pinned_checksum() { # pinned_checksum <asset-filename>
  local asset="$1"
  awk -v a="$asset" '
    /^[[:space:]]*#/ {next} /^[[:space:]]*$/ {next}
    $2 == a {print $1; exit}
  ' "$CHECKSUMS_FILE" 2>/dev/null || true
}

# Verify a file against checksums.txt; TOFU-pin if absent.
verify_or_pin() { # verify_or_pin <file> <asset-filename>
  local file="$1" asset="$2" want got
  got="$(sha256_of "$file")"
  want="$(pinned_checksum "$asset")"

  if [ -n "$want" ]; then
    if [ "$want" = "$got" ]; then
      ok "Checksum verified: ${asset}"
    else
      err "Checksum MISMATCH for ${asset}"
      err "  expected (pinned): ${want}"
      err "  got      (download): ${got}"
      err "Refusing to install a binary that does not match the pin."
      rm -f "$file"
      exit 1
    fi
  else
    warn "No pinned checksum for ${asset} — trust-on-first-use."
    warn "  Computed: ${got}"
    warn "  Appending to checksums.txt. REVIEW against upstream and commit it."
    printf '%s  %s\n' "$got" "$asset" >> "$CHECKSUMS_FILE"
  fi
}

# --- govc -------------------------------------------------------------------
install_govc() {
  local target="${BIN_DIR}/govc"
  if [ "$FORCE" -eq 0 ] && [ -x "$target" ]; then
    ok "govc already present: $("$target" version 2>/dev/null || echo present)"
    return 0
  fi
  [ "$OFFLINE" -eq 1 ] && { warn "govc missing and --offline set; skipping."; return 0; }

  local asset="govc_${GOVC_OS}_${GOVC_ARCH}.tar.gz"
  local url="https://github.com/vmware/govmomi/releases/download/${GOVC_VERSION}/${asset}"
  local tmp; tmp="$(mktemp -d)"
  info "Downloading govc ${GOVC_VERSION} (${asset}) ..."
  fetch "$url" "${tmp}/${asset}" || die "Failed to download govc from ${url}"
  verify_or_pin "${tmp}/${asset}" "$asset"
  tar -xzf "${tmp}/${asset}" -C "$tmp" govc || die "Failed to extract govc"
  install -m 0755 "${tmp}/govc" "$target"
  rm -rf "$tmp"
  ok "Installed govc -> ${target} ($("$target" version 2>/dev/null || echo ok))"
}

# --- jq ---------------------------------------------------------------------
install_jq() {
  local target="${BIN_DIR}/jq"
  if [ "$FORCE" -eq 0 ] && [ -x "$target" ]; then
    ok "jq already present: $("$target" --version 2>/dev/null || echo present)"
    return 0
  fi
  [ "$OFFLINE" -eq 1 ] && { warn "jq missing and --offline set; skipping."; return 0; }

  # jq 1.7.1 asset names: jq-linux-amd64, jq-linux-arm64, jq-macos-amd64, jq-macos-arm64
  local asset="jq-${JQ_OS}-${JQ_ARCH}"
  local url="https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/${asset}"
  local tmp; tmp="$(mktemp -d)"
  info "Downloading jq ${JQ_VERSION} (${asset}) ..."
  fetch "$url" "${tmp}/${asset}" || die "Failed to download jq from ${url}"
  verify_or_pin "${tmp}/${asset}" "$asset"
  install -m 0755 "${tmp}/${asset}" "$target"
  rm -rf "$tmp"
  ok "Installed jq -> ${target} ($("$target" --version 2>/dev/null || echo ok))"
}

# --- CLI install (symlink onto PATH) ----------------------------------------
# Auto: prefer ~/.local/bin (no root); fall back to /usr/local/bin via sudo only
# with consent. --user / --system force a scope; --no-cli skips entirely.
_on_path() { case ":${PATH}:" in *":$1:"*) return 0;; *) return 1;; esac; }

_link_into() { # _link_into <dir> [use_sudo]
  local dir="$1" sudo="${2:-}"
  local link="${dir}/vminv" src="${SCRIPT_DIR}/vminv"
  $sudo mkdir -p "$dir" 2>/dev/null || { warn "Cannot create ${dir}"; return 1; }
  # If something is already there, only replace a symlink that points to us.
  if [ -e "$link" ] || [ -L "$link" ]; then
    if [ -L "$link" ] && [ "$(readlink "$link" 2>/dev/null)" = "$src" ]; then
      ok "CLI already linked: ${link}"; _path_hint "$dir"; return 0
    fi
    if [ "$FORCE" -eq 0 ]; then warn "${link} exists and is not our symlink — leaving it (use --force)."; return 1; fi
    $sudo rm -f "$link" || { warn "Cannot replace ${link}"; return 1; }
  fi
  $sudo ln -s "$src" "$link" 2>/dev/null || { warn "Cannot symlink ${link}"; return 1; }
  ok "Installed CLI: ${link} -> ${src}"
  _path_hint "$dir"
  return 0
}

_path_hint() { # warn if dir not on PATH, with shell-appropriate guidance
  local dir="$1"
  _on_path "$dir" && return 0
  warn "${dir} is not on your PATH. Add it, e.g.:"
  case "${SHELL##*/}" in
    zsh)  warn "  echo 'export PATH=\"${dir}:\$PATH\"' >> ~/.zshrc && source ~/.zshrc" ;;
    *)    warn "  echo 'export PATH=\"${dir}:\$PATH\"' >> ~/.bashrc && source ~/.bashrc" ;;
  esac
}

# Best-effort man-page install into the user man path.
install_man() {
  local src="${SCRIPT_DIR}/man/vminv.1" dest="${HOME}/.local/share/man/man1"
  [ -f "$src" ] || return 0
  mkdir -p "$dest" 2>/dev/null || return 0
  if cp "$src" "${dest}/vminv.1" 2>/dev/null; then
    ok "Installed man page -> ${dest}/vminv.1 (man vminv)"
  fi
  return 0
}

install_cli() {
  [ "$INSTALL_CLI" -eq 1 ] || { info "Skipping CLI install (--no-cli)."; return 0; }
  chmod +x "${SCRIPT_DIR}/vminv" 2>/dev/null || true
  install_man

  local user_dir="${HOME}/.local/bin" sys_dir="/usr/local/bin"
  case "$INSTALL_SCOPE" in
    user)   _link_into "$user_dir" ;;
    system)
      if [ "$(id -u)" -eq 0 ]; then _link_into "$sys_dir"
      elif command -v sudo >/dev/null 2>&1; then info "Installing system-wide (sudo) ..."; _link_into "$sys_dir" sudo
      else warn "System install needs root/sudo; falling back to ${user_dir}."; _link_into "$user_dir"; fi ;;
    *)  # auto: user-local first
      _link_into "$user_dir" || warn "User-local CLI install did not complete." ;;
  esac
}

# --- Config scaffold --------------------------------------------------------
scaffold_config() {
  [ -f "$ENV_EXAMPLE" ] || die "Missing ${ENV_EXAMPLE} (repo incomplete?)"
  if [ -f "$ENV_FILE" ]; then
    ok ".env already exists — leaving it untouched."
  else
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    ok "Created .env from config.example.env (mode 600)."
    warn "Edit .env: set VCENTER_HOST / VCENTER_USER. Do NOT store the password there."
  fi
}

# --- Readiness summary ------------------------------------------------------
readiness() {
  echo
  printf '%s================ vminv readiness ================%s\n' "$C_BOLD" "$C_RST"
  local ready=1
  for t in govc jq; do
    if [ -x "${BIN_DIR}/${t}" ]; then
      printf '  %s[ok]%s %-6s %s\n' "$C_GRN" "$C_RST" "$t" "$("${BIN_DIR}/${t}" --version 2>/dev/null || "${BIN_DIR}/${t}" version 2>/dev/null || echo present)"
    else
      printf '  %s[--]%s %-6s missing\n' "$C_RED" "$C_RST" "$t"; ready=0
    fi
  done
  if [ -f "$ENV_FILE" ]; then
    printf '  %s[ok]%s .env    present\n' "$C_GRN" "$C_RST"
  else
    printf '  %s[--]%s .env    missing\n' "$C_RED" "$C_RST"; ready=0
  fi
  if command -v vminv >/dev/null 2>&1; then
    printf '  %s[ok]%s cli     %s\n' "$C_GRN" "$C_RST" "$(command -v vminv)"
  else
    printf '  %s[!!]%s cli     not on PATH (see notes above)\n' "$C_YEL" "$C_RST"
  fi
  printf '%s=================================================%s\n' "$C_BOLD" "$C_RST"
  echo
  if [ "$ready" -eq 1 ]; then
    ok "Ready. Next steps:"
    echo "    1) vminv configure                 (create a profile, aws-cli style)"
    echo "    2) vminv --profile <name> --dry-run (read-only connectivity check)"
    echo "    3) vminv --profile <name>           (full scan)"
    echo "  Or without a profile: edit .env, then  vminv --dry-run"
    echo "  Shell completion:  vminv completion bash >> ~/.bashrc   (or zsh|fish)"
  else
    warn "Not fully ready — see missing items above. Re-run ./setup.sh."
  fi
}

# --- Main -------------------------------------------------------------------
main() {
  info "vminv setup starting${PLATFORM_NOTE:-}"
  mkdir -p "$BIN_DIR"
  detect_platform
  install_govc
  install_jq
  install_cli
  scaffold_config
  readiness
}
main
