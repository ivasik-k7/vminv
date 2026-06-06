#!/usr/bin/env bash
#
# lib/upload.sh — pluggable destination uploader.
#
# A run's output directory is packed into a single timestamped .tar.gz and
# shipped to a destination identified by a URL scheme. New backends are one
# `case` arm + one helper, so destinations stay "very flexible":
#
#   s3://bucket/prefix              AWS S3            (needs: aws)
#   gs://bucket/prefix              Google Cloud      (needs: gcloud)
#   az://container/prefix          Azure Blob        (needs: az; AZ_STORAGE_ACCOUNT)
#   sftp://user@host/path           SFTP/SCP          (needs: scp)
#   https://host/repo/path          Generic PUT / JFrog Artifactory (needs: curl)
#   file:///abs/path  |  /abs/path  Local / NFS dir   (cp)
#
# Auth is taken from the ambient environment / standard credential chains and
# is never logged:
#   AWS_*  (S3) · gcloud auth (GS) · az login/AZURE_STORAGE_* (Azure) ·
#   ssh keys/agent (SFTP) · UPLOAD_TOKEN (Bearer) or UPLOAD_HEADER (https/JFrog)
#
# Sourced by vminv; requires lib/common.sh.

have_tool() { command -v "$1" >/dev/null 2>&1; }

# Pack a run directory into a single tarball; echoes the tarball path.
pack_run() { # pack_run <run_dir>
  local run="$1" name parent tgz
  name="$(basename "$run")"; parent="$(dirname "$run")"
  local td; td="$(mktemp -d)"; register_tmp "$td"
  tgz="${td}/${name}.tar.gz"
  tar -czf "$tgz" -C "$parent" "$name" || { err "Failed to pack ${run}"; return 1; }
  printf '%s' "$tgz"
}

# --- backends ---------------------------------------------------------------
_up_local() { # _up_local <file> <dest-dir>
  local f="$1" d="${2#file://}"
  mkdir -p "$d" || { err "Cannot create ${d}"; return 1; }
  cp "$f" "${d}/" && ok "Uploaded to ${d}/$(basename "$f")"
}
_up_s3() { # _up_s3 <file> <s3://bucket/prefix>
  have_tool aws || { err "aws CLI not found (required for s3:// destinations)"; return 1; }
  local f="$1" d="${2%/}"
  aws s3 cp "$f" "${d}/$(basename "$f")" >/dev/null && ok "Uploaded to ${d}/$(basename "$f")"
}
_up_gs() { # _up_gs <file> <gs://bucket/prefix>
  local f="$1" d="${2%/}"
  if have_tool gcloud; then gcloud storage cp "$f" "${d}/$(basename "$f")" >/dev/null
  elif have_tool gsutil; then gsutil cp "$f" "${d}/$(basename "$f")" >/dev/null
  else err "gcloud/gsutil not found (required for gs:// destinations)"; return 1; fi
  ok "Uploaded to ${d}/$(basename "$f")"
}
_up_az() { # _up_az <file> <az://container/prefix>  (needs AZ_STORAGE_ACCOUNT)
  have_tool az || { err "az CLI not found (required for az:// destinations)"; return 1; }
  [ -n "${AZ_STORAGE_ACCOUNT:-}" ] || { err "AZ_STORAGE_ACCOUNT must be set for az:// destinations"; return 1; }
  local f="$1" rest="${2#az://}" container="${rest%%/*}" prefix="${rest#*/}"
  [ "$prefix" = "$rest" ] && prefix=""
  az storage blob upload --account-name "$AZ_STORAGE_ACCOUNT" --container-name "$container" \
     --name "${prefix:+$prefix/}$(basename "$f")" --file "$f" --only-show-errors >/dev/null \
    && ok "Uploaded to az://${container}/${prefix:+$prefix/}$(basename "$f")"
}
_up_sftp() { # _up_sftp <file> <sftp://user@host/path>
  have_tool scp || { err "scp not found (required for sftp:// destinations)"; return 1; }
  local f="$1" rest="${2#sftp://}"; rest="${rest#scp://}"
  local hostpart="${rest%%/*}" path="/${rest#*/}"
  scp -q "$f" "${hostpart}:${path}/$(basename "$f")" && ok "Uploaded to ${hostpart}:${path}/$(basename "$f")"
}
_up_http() { # _up_http <file> <https://host/repo/path>  (JFrog Artifactory / generic PUT)
  have_tool curl || { err "curl not found (required for http(s) destinations)"; return 1; }
  local f="$1" base="${2%/}" url="${2%/}/$(basename "$f")"
  local -a auth=()
  [ -n "${UPLOAD_TOKEN:-}" ]  && auth+=(-H "Authorization: Bearer ${UPLOAD_TOKEN}")
  [ -n "${UPLOAD_HEADER:-}" ] && auth+=(-H "${UPLOAD_HEADER}")
  if curl -fsSL --retry 2 -T "$f" "${auth[@]}" "$url" >/dev/null; then ok "Uploaded to ${url}"
  else err "HTTP upload failed (${base})"; return 1; fi
}

# upload_file <file> <dest-url>
upload_file() {
  local f="$1" dest="$2"
  [ -n "$dest" ] || { err "No upload destination configured (set UPLOAD_DEST or pass --dest)"; return 1; }
  [ -f "$f" ] || { err "Nothing to upload: ${f}"; return 1; }
  info "Uploading $(basename "$f") -> ${dest}"
  case "$dest" in
    s3://*)            _up_s3   "$f" "$dest" ;;
    gs://*)            _up_gs   "$f" "$dest" ;;
    az://*)            _up_az   "$f" "$dest" ;;
    sftp://*|scp://*)  _up_sftp "$f" "$dest" ;;
    http://*|https://*) _up_http "$f" "$dest" ;;
    file://*)          _up_local "$f" "$dest" ;;
    /*|./*|~*)         _up_local "$f" "$dest" ;;
    *) err "Unknown destination scheme: '${dest}' (expected s3://, gs://, az://, sftp://, https://, file:// or a path)"; return 1 ;;
  esac
}

# upload_run <run_dir> <dest-url> : pack + ship a whole run directory.
upload_run() {
  local run="$1" dest="$2" tgz
  [ -d "$run" ] || { err "Run directory not found: ${run}"; return 1; }
  tgz="$(pack_run "$run")" || return 1
  upload_file "$tgz" "$dest"; local rc=$?
  rm -rf "$(dirname "$tgz")"
  return $rc
}
