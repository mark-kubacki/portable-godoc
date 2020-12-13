#!/bin/bash
set -eupo pipefail

: ${remote_url:="gs://${PROJECT_ID}_cloudbuild/cache/godoc"}
: ${nocache_prefix:=".skipcache"}

cloud::build::cache::stash() {
  if [[ -e "${nocache_prefix}-${tag}" ]]; then
    return 0
  fi

  local TMPDIR="$(mktemp -d)"
  tar --sort=name --owner=0:0 --group=0:0 --gzip \
    -C "${folder}/" -cf "${TMPDIR}/${tag}.tgz" .
  gsutil cp "${TMPDIR}/${tag}.tgz" "${remote_url}/${tag}.tgz"
  rm -rf "${TMPDIR}" &
}

cloud::build::cache::restore() {
  local TMPDIR="$(mktemp -d)"
  if gsutil cp "${remote_url}/${tag}.tgz" "${TMPDIR}/"; then
    tar -C "${folder}/" -xaf "${TMPDIR}/${tag}.tgz"
    touch "${nocache_prefix}-${tag}"
  fi
  rm -rf "${TMPDIR}" &
}

if (( $# >= 2 )); then
  while (( $# >= 2 )); do
    folder="${2}"
    tag="${folder//\//-}"
    if [[ "${tag:0:1}" == "-" ]]; then tag="${tag:1}"; fi
    if [[ "${tag:(-1)}" == "-" ]]; then tag="${tag:0:(-1)}"; fi

    "${1}"

    shift 2
  done

  wait
fi
