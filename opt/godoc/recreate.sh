#!/bin/bash
set -eupo pipefail

: ${PN:="godoc"}
: ${PV:="2"}
: ${ARCHS:="amd64 arm64 riscv64"}

: ${CACHE_DIRECTORY:="/usr/src"}

declare -r since_work_epoch="2020-12-07"

# Clones a bare and truncated copy, using $since_work_epoch,
# intended to be stable, small, and suitable for caching.
# Also minimizes data transferrd from those remotes.
#
# Subsequent runs will fetch any new history.
#
#   $1       Dir to clone into, below prefix $CACHE_DIRECTORY.
#   $2 $3    Origin name and URL, for git-scm.
#   N+3 N+4  Pairs of remotes, forks of $2, with branch(es) also fetched.
#            Their URLs will written on the first run, and not updated hence.
git::fetch() {
  pushd .
  cd "${CACHE_DIRECTORY}"/
  local mirrors=(${2})
  if [[ ! -d ${1} ]]; then
    for mirror in "${mirrors[@]}"; do
      set -x
      git clone \
        --single-branch --no-tags --bare \
        --shallow-since=${since_work_epoch} \
        "${mirror}" ${1} \
      && break
      set +x
    done
  fi
  if [[ ! -d ${1} ]]; then
    for mirror in "${mirrors[@]}"; do
      git clone \
        --single-branch --no-tags --bare \
        "${mirror[0]}" ${1} \
      && break
    done
  fi
  cd ${1}

  local remotes=("origin")
  shift 2
  while (( $# >= 2 )); do
    if ! git remote | egrep -q -e "^${1}\$"; then
      git remote add ${1} "${2}"
    fi
    remotes+=("${1}")
    shift 2
  done

  # To make this idempotent, fetch again.
  git fetch \
    --no-tags --shallow-since=${since_work_epoch} \
    --multiple "${remotes[@]}"

  popd
}

# Executes a deferred integration into the then current active branch.
# Args and their order follows that of git::integrate, only shifted by 2
# omitting the integration target for those feature branches.
# Is part of said func to catch and rollback on any failed git-merge.
#
#   N, N+1   Remotes to integrate; only their name (N) will be used.
git::integrate::remotes() {
  while (( $# >= 2 )); do
    git merge $(git branch -a --list "${1}/*") -m "Merge remote-tracking branches ${1}/*"
    shift 2
  done
}

# Merges feature branches into the origin.
# Use this if any have not been upstreamed.
#
# Run this in a TMPDIR because it'll actually clone from those
# cached origins found in $CACHE_DIRECTORY.
#
# Args like for git::fetch.
git::integrate() {
  if [[ ! -d "${CACHE_DIRECTORY}"/${1} ]]; then
    git::fetch "$@"
  fi

  # Gets the default branch.
  git clone --shared "${CACHE_DIRECTORY}"/${1} ${1}
  pushd .
  cd ${1}
  git config user.email "you@example.com"
  git config user.name "Your Name"

  # Also get any remotes. Their names will be retained.
  cat >>.git/config <<EOF
[remote "remotes"]
	url = ${CACHE_DIRECTORY}/${1}
	fetch = +refs/remotes/*:refs/remotes/*
EOF
  git fetch remotes

  shift 2
  local rollback=0
  while true; do
    git checkout --detach origin/HEAD~${rollback}
    if git::integrate::remotes "$@"; then
      if (( ${rollback} > 0 )); then
        >&2 printf "WARN: Had to revert to: HEAD~%d\n" ${rollback}
      fi
      popd
      return 0
    fi
    git merge --abort || true
    let rollback+=1
    # Don't try rebases as they likely won't work due to changes in go.sum or go.mod.
  done

  popd
}

# Centralizes the compile flags for Go's compiler.
#
#   $1       Full path to the desired build artifact.
go::compile() {
  env GOARCH=${ARCH} CGO_ENABLED=0 GOPROXY=off \
  go build -mod=readonly \
    -trimpath -ldflags "-w -s -extldflags=-static" \
    -o "${1}" .
}

# Collects common steps in synthetisizing from a repo with deferred,
# yet to be integrated, feature branches.
#
# Will work in a TMPDIR of its own creation, that gets abandoned.
#
# Args and envvar are for git::fetch.
#   $PN          To catch the datetime of the last CL that's no merge.
#   $submodule   Relative workdir within $1.
#   $visitorFn   Called for every in ARCHS.
#   $teardownFn  Run once if not empty, after all builds succeeded.
compile::with_visitor() {
  local D="${PWD}"
  pushd .
  cd "$(mktemp -d)"

  git::integrate "$@"
  cd "${1}/${submodule}"
  git log --since="${since_work_epoch}" --no-merges --pretty=format:"%ct %ci" \
    | sort -r >"${D}/.source_date_epoch-${PN}"

  mkdir -p "${D}/usr/bin"

  local t_start=${EPOCHSECONDS}
  go mod download
  printf "go mod download: %d seconds\n" $(( ${EPOCHSECONDS} - ${t_start} ))

  local ARCH
  for ARCH in ${ARCHS}; do
    "$visitorFn"
  done
  if [[ "$teardownFn" != "" ]]; then
    "$teardownFn"
  fi

  popd
}

# Funcs for the binary 'godoc' found in "golang-tools".
compile::visitorFn::godoc() {
  local t_start=${EPOCHSECONDS}
  go::compile "${D}/usr/bin/${PN}~${ARCH}"
  printf "%s: %d seconds\n" ${ARCH} $(( ${EPOCHSECONDS} - ${t_start} ))
}
compile::godoc() {
  mkdir -p "usr/bin"

  local PN="godoc" submodule="cmd/godoc"
  local visitorFn="compile::visitorFn::godoc" teardownFn=""
  compile::with_visitor \
    "golang-tools" https://go.googlesource.com/tools \
    "mark" https://github.com/wmark/golang-tools.git
}

# Funcs for the builder and runner.
# Upstream has named their repo "playground".
compile::visitorFn::playground() {
  local t_start=${EPOCHSECONDS}
  go::compile "${D}/usr/libexec/${PN}-builder~${ARCH}"
  cd oneshot
  go::compile "${D}/usr/libexec/${PN}-runner~${ARCH}"
  cd ..
  printf "%s: %d seconds\n" ${ARCH} $(( ${EPOCHSECONDS} - ${t_start} ))
}
compile::visitorFn::capture_static() {
  cp -ra --reflink=auto \
    LICENSE edit.html static \
    "${D}/usr/share/godoc/"
}
compile::playground() {
  mkdir -p "usr/share/${PN}" "usr/libexec"

  local PN="playground" submodule=""
  local visitorFn="compile::visitorFn::playground"
  local teardownFn="compile::visitorFn::capture_static"
  compile::with_visitor \
    "golang-playground" https://go.googlesource.com/playground \
    "mark" https://github.com/wmark/golang-playground.git
}

# Packages *.deb files, with steps distilled from a hypothetical
# run of "debuild --no-lintian -b -d".
#
# Works on artifacts generated by compile::{playground,godoc}.
package::deb() {
  # For dpkg-deb and reproducible builds.
  local SOURCE_DATE_EPOCH="$(cat .source_date_epoch-* \
    | sort -r | head -n 1 | cut -d ' ' -f 1)"
  readonly SOURCE_DATE_EPOCH

  # Apparently 'install' is an alias on some machines.
  local put=(/usr/bin/install -D --owner=0 --group=0)
  local ARCH
  for ARCH in ${ARCHS}; do
    local t_start=${EPOCHSECONDS}

    local deb_arch=${ARCH}
    # They don't agree, so translate from Go's to Debian's nomenclature:
    case "${ARCH}" in
      386) deb_arch="i386" ;;
      arm) deb_arch="armhf" ;;
    esac

    local D="$(mktemp -d)"

    "${put[@]}" --mode=0755 \
      usr/libexec/playground-runner~${ARCH} \
      "${D}"/usr/libexec/${PN}-runner
    "${put[@]}" --mode=0755 \
      usr/libexec/playground-builder~${ARCH} \
      "${D}"/usr/libexec/${PN}-builder
    # Standalone godoc can be used to inspect other than the global
    # directories with code, hence be called individually.
    "${put[@]}" --mode=0755 \
      usr/bin/${PN}~${ARCH} \
      "${D}"/usr/bin/${PN}

    mkdir -p "${D}"/usr/share/${PN}/
    cp -ra --reflink=auto --no-preserve=mode,ownership \
      usr/share/${PN}/* \
      "${D}"/usr/share/${PN}/
    "${put[@]}" --mode=0644 \
      --target-directory "${D}"/usr/lib/systemd/system/ \
      usr/lib/systemd/system/${PN}-*

    "${put[@]}" --mode=0754 \
      --target-directory "${D}"/DEBIAN/ \
      opt/${PN}/${PN}.p* 
    "${put[@]}" --mode=0644 \
      --target-directory "${D}"/DEBIAN/ \
      opt/${PN}/control

    # Those are for the actualy portable service, else won't work.
    sed -i \
      -e "/BindReadOnlyPaths/d" \
      "${D}"/usr/lib/systemd/system/*.service

    sed -i \
      -e "/^Architecture/c\Architecture: ${deb_arch}" \
      "${D}"/DEBIAN/control
    printf "Installed-Size: %d\n" \
      $(du -s --apparent-size --block-size=1024 "${D}" | cut -f 1) \
      >>"${D}"/DEBIAN/control

    # In case hashes don't match the build is not reproducible,
    # and as I want to know when that started display those hashes.
    # Go with MD5 because Cloud Storage uses it too.
    (cd "${D}"; md5sum $(find -type f | cut -b 3- | sort))
    env SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH \
      dpkg-deb -z9 -Zxz --build "${D}" ${PN}_${PV}_${deb_arch}.deb
    md5sum ${PN}_${PV}_${deb_arch}.deb

    printf "%s: %d seconds\n" ${ARCH} $(( ${EPOCHSECONDS} - ${t_start} ))
  done

  # Size, owner, apparent dates - for a later inspection and debugging.
  ls -hlAS *.deb
}

if (( ${#BASH_SOURCE[@]} <= 1 )); then
  if (( $# >= 1 )); then
    "$@"
  fi
fi
