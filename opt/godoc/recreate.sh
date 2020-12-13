#!/bin/bash
set -eupo pipefail

: ${PN:="godoc"}
: ${PV:="1"}
: ${ARCHS:="amd64 arm64 riscv64"}

declare -r since_work_epoch="2020-12-07"

git::fetch() {
  pushd .
  cd /usr/src/
  if [[ ! -d ${1} ]]; then
    git clone \
      --single-branch --no-tags --shallow-since=${since_work_epoch} \
      --bare \
      "${2}" ${1}
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
    --multiple \
    "${remotes[@]}"

  popd
}

git::integrate::remotes() {
  while (( $# >= 2 )); do
    git merge $(git branch -a --list "${1}/*") -m "Merge remote-tracking branches ${1}/*"
    shift 2
  done
}

git::integrate() {
  if [[ ! -d /usr/src/${1} ]]; then
    git::fetch "$@"
  fi

  # Gets the default branch.
  git clone --shared /usr/src/${1} ${1}
  pushd .
  cd ${1}
  git config user.email "you@example.com"
  git config user.name "Your Name"

  # Also get any remotes. Their names will be retained.
  cat >>.git/config <<EOF
[remote "remotes"]
	url = /usr/src/${1}
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

go::compile() {
  env GOARCH=${ARCH} CGO_ENABLED=0 GOPROXY=off \
  go build -mod=readonly \
    -trimpath -ldflags "-w -s -extldflags=-static" \
    -o "${1}" .
}

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

package::deb() {
  export SOURCE_DATE_EPOCH="$(cat .source_date_epoch-* | sort -r | head -n 1 | cut -d ' ' -f 1)"
  # Above is for dpkg-deb and reproducible builds.

  # Apparently 'install' is an alias on some machines.
  local put=(/usr/bin/install -D --owner=0 --group=0)
  local ARCH
  for ARCH in ${ARCHS}; do
    local t_start=${EPOCHSECONDS}

    local deb_arch=${ARCH}
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

    sed -i \
      -e "/BindReadOnlyPaths/d" \
      "${D}"/usr/lib/systemd/system/*.service

    sed -i \
      -e "/^Architecture/c\Architecture: ${deb_arch}" \
      "${D}"/DEBIAN/control
    printf "Installed-Size: %d\n" \
      $(du -s --apparent-size --block-size=1024 "${D}" | cut -f 1) \
    >>"${D}"/DEBIAN/control

    # Be consistent: Cloud storage uses MD5, and this is no adversary build environment.
    (cd "${D}"; md5sum $(find -type f | cut -b 3- | sort))
    dpkg-deb -z9 -Zxz --build "${D}" ${PN}_${PV}_${deb_arch}.deb
    md5sum ${PN}_${PV}_${deb_arch}.deb

    printf "%s: %d seconds\n" ${ARCH} $(( ${EPOCHSECONDS} - ${t_start} ))
  done
  ls -hlAS *.deb
}

if (( $# >= 1 )); then
  "$@"
fi
