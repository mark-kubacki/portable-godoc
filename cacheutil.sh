#!/bin/bash
set -eupo pipefail

: ${remote_url:="gs://${PROJECT_ID}_cloudbuild/cache/godoc"}
: ${nocache_prefix:=".skipcache"}

# Reproducibily derives a tag from the given folder name ($1)
# that is safe for use in filenames, such as for locking/skipping.
cloud::build::cache::tag_from_folder() {
  local tag="${1//\//-}"
  if [[ "${tag:0:1}" == "-" ]]; then tag="${tag:1}"; fi
  if [[ "${tag:(-1)}" == "-" ]]; then tag="${tag:0:(-1)}"; fi
  printf "${tag}\n"
}

# Uploads the given folder to cloud storage.
# Is a no-op if a "nocache" file exists, to prevent uploading
# for cases such as idempotent caching.
#
# Abandons its temporary folder (run with PrivateTmp=true).
#
#   $1  is the source folder
cloud::build::cache::stash() {
  local tag="$(cloud::build::cache::tag_from_folder "${1}")"

  if [[ -e "${nocache_prefix}-${tag}" ]]; then
    return 0
  fi

  local TMPDIR="$(mktemp -d)"
  tar --sort=name --owner=0:0 --group=0:0 --gzip \
    -C "${1}/" -cf "${TMPDIR}/${tag}.tgz" .
  gsutil cp "${TMPDIR}/${tag}.tgz" "${remote_url}/${tag}.tgz"
}

# Upserts contents into the given folder,
# that is expected to be empty or artifacts might interfere.
# Abandons its temporary folder.
#
#   $1  is the target folder
cloud::build::cache::restore() {
  local TMPDIR="$(mktemp -d)"
  local tag="$(cloud::build::cache::tag_from_folder "${1}")"

  if gsutil cp "${remote_url}/${tag}.tgz" "${TMPDIR}/"; then
    tar -C "${1}/" -xaf "${TMPDIR}/${tag}.tgz"
    touch "${nocache_prefix}-${tag}"
  fi
}

if (( ${#BASH_SOURCE[@]} <= 1 )); then
  while (( $# >= 2 )); do
    "${1}" "${2}"
    shift 2
  done
fi
