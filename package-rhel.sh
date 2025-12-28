#!/usr/bin/env bash
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

VERSION=""
RELEASE="1"
OUTDIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2;;
    --release) RELEASE="${2:-}"; shift 2;;
    --outdir)  OUTDIR="${2:-}"; shift 2;;
    -h|--help)
      cat <<EOF
Usage: $0 --version <x.y.z> [--release <n>] [--outdir <dir>]
EOF
      exit 0;;
    *) die "unknown arg: $1";;
  esac
done

[[ -n "$VERSION" ]] || die "missing --version"
[[ "$RELEASE" =~ ^[0-9]+$ ]] || die "invalid --release"

PKGNAME="xray-core"
UPSTREAM_REPO="https://github.com/XTLS/Xray-core.git"

# Align with official Xray-install defaults
LOCAL_PREFIX="/usr/local"
DAT_PATH="${LOCAL_PREFIX}/share/xray"
JSON_PATH="${LOCAL_PREFIX}/etc/xray"

[[ -n "${OUTDIR:-}" ]] || OUTDIR="$PWD"
mkdir -p "$OUTDIR"

if command -v dnf >/dev/null 2>&1; then
  dnf -y makecache
  dnf -y install \
    git ca-certificates curl \
    golang \
    rpm-build rpmdevtools redhat-rpm-config \
    systemd-rpm-macros \
    tar gzip findutils which shadow-utils \
    coreutils
  dnf -y clean all || true
else
  die "dnf not found"
fi

need_cmd git
need_cmd go
need_cmd rpmbuild
need_cmd sha256sum
need_cmd tar

echo "[*] go: $(go version)"
echo "[*] arch: $(uname -m)"
echo "[*] outdir: $OUTDIR"
echo "[*] prefix: $LOCAL_PREFIX"
echo "[*] DAT_PATH: $DAT_PATH"
echo "[*] JSON_PATH: $JSON_PATH"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SRC="$WORK/src"
OUT="$WORK/out"
mkdir -p "$SRC" "$OUT"

git clone --depth 1 --branch "v${VERSION}" "$UPSTREAM_REPO" "$SRC"

COMMIT="$(cd "$SRC" && git rev-parse --short HEAD)"
echo "[*] upstream commit: $COMMIT"

cd "$SRC"
export CGO_ENABLED=0
go mod download
go build -trimpath -buildvcs=false \
  -ldflags "-s -w -X github.com/xtls/xray-core/core.build=${COMMIT}" \
  -o "$OUT/xray" ./main

[[ -f "$OUT/xray" ]] || die "xray build failed"
chmod 0755 "$OUT/xray"

mkdir -p "$WORK/resources"
LIST=('Loyalsoldier v2ray-rules-dat geoip geoip' 'Loyalsoldier v2ray-rules-dat geosite geosite')
for i in "${LIST[@]}"; do
  INFO=($(echo $i | awk 'BEGIN{FS=" ";OFS=" "} {print $1,$2,$3,$4}'))
  FILE_NAME="${INFO[3]}.dat"
  HASH="$(curl -fsSL "https://raw.githubusercontent.com/${INFO[0]}/${INFO[1]}/release/${INFO[2]}.dat.sha256sum" | awk '{print $1}')"
  curl -fsSL "https://raw.githubusercontent.com/${INFO[0]}/${INFO[1]}/release/${INFO[2]}.dat" -o "$WORK/resources/${FILE_NAME}"
  [ -s "$WORK/resources/${FILE_NAME}" ] || die "${FILE_NAME} download failed/empty"
  [ "$(sha256sum "$WORK/resources/${FILE_NAME}" | awk '{print $1}')" == "${HASH}" ] || die "The HASH key of ${FILE_NAME} does not match cloud one."
done

RPMTOP="$HOME/rpmbuild"
for d in BUILD BUILDROOT RPMS SOURCES SPECS SRPMS; do
  mkdir -p "$RPMTOP/$d"
done

STAGE="$RPMTOP/BUILD/${PKGNAME}-${VERSION}"
rm -rf "$STAGE"

mkdir -p "$STAGE${DAT_PATH}" "$STAGE${JSON_PATH}"

install -m0755 "$OUT/xray" "$STAGE/xray"
install -m0644 "$WORK/resources/geoip.dat" "$STAGE/geoip.dat"
install -m0644 "$WORK/resources/geosite.dat" "$STAGE/geosite.dat"

cat >"$STAGE${JSON_PATH}/config.json" <<'EOF'
{ "log": { "loglevel": "warning" }, "inbounds": [], "outbounds": [] }
EOF

cat >"$STAGE/xray.service" <<EOF
[Unit]
Description=Xray Service
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
ExecStart=${LOCAL_PREFIX}/bin/xray run -config ${JSON_PATH}/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

cat >"$STAGE/xray@.service" <<EOF
[Unit]
Description=Xray Service (Instance)
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
ExecStart=${LOCAL_PREFIX}/bin/xray run -config ${JSON_PATH}/%i.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

[[ -f "$SRC/LICENSE" ]] && cp "$SRC/LICENSE" "$STAGE/LICENSE"
[[ -f "$SRC/README.md" ]] && cp "$SRC/README.md" "$STAGE/README.md"

# build tarball from STAGE
tar -C "$RPMTOP/BUILD" -czf "$RPMTOP/SOURCES/${PKGNAME}-${VERSION}.tar.gz" "${PKGNAME}-${VERSION}"

cat >"$RPMTOP/SPECS/${PKGNAME}.spec" <<EOF
Name: ${PKGNAME}
Version: ${VERSION}
Release: ${RELEASE}%{?dist}
Summary: Xray-core (layout aligned with official install-release.sh)

License: MPL-2.0
URL: https://github.com/XTLS/Xray-core
Source0: %{name}-%{version}.tar.gz
BuildArch: %{_arch}
%global debug_package %{nil}

Requires: systemd

%description
Xray-core is a platform for building proxies.

%prep
%autosetup -n %{name}-%{version}

%build

%install
rm -rf %{buildroot}

# binary -> /usr/local/bin/xray
install -D -m0755 xray %{buildroot}${LOCAL_PREFIX}/bin/xray

# geodata -> /usr/local/share/xray/*.dat
install -D -m0644 geoip.dat %{buildroot}${DAT_PATH}/geoip.dat
install -D -m0644 geosite.dat %{buildroot}${DAT_PATH}/geosite.dat

# config -> /usr/local/etc/xray/config.json
# IMPORTANT: must be a path inside the unpacked source tree, NOT host /usr/local/...
install -D -m0644 usr/local/etc/xray/config.json %{buildroot}${JSON_PATH}/config.json

# unit names aligned with official (still installed into %{_unitdir})
install -D -m0644 xray.service %{buildroot}%{_unitdir}/xray.service
install -D -m0644 xray@.service %{buildroot}%{_unitdir}/xray@.service

%post
%systemd_post xray.service

%preun
%systemd_preun xray.service

%postun
%systemd_postun_with_restart xray.service

%files
%license LICENSE
%doc README.md

${LOCAL_PREFIX}/bin/xray
${DAT_PATH}/geoip.dat
${DAT_PATH}/geosite.dat
%config(noreplace) ${JSON_PATH}/config.json

%{_unitdir}/xray.service
%{_unitdir}/xray@.service

%changelog
* Sun Dec 28 2025 Jie Xu <xujie@example.invalid> - ${VERSION}-${RELEASE}
- Build aligned layout with official install-release.sh
EOF

rpmbuild -ba "$RPMTOP/SPECS/${PKGNAME}.spec"

shopt -s nullglob
rpms=( "$RPMTOP"/RPMS/*/"${PKGNAME}-${VERSION}-${RELEASE}"*.rpm )
(( ${#rpms[@]} > 0 )) || die "no rpm produced"
cp -v "${rpms[@]}" "$OUTDIR/"

ls -la "$OUTDIR"
