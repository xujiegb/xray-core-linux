#!/usr/bin/env bash
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

VERSION=""
REVISION="1"
OUTDIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2;;
    --revision) REVISION="${2:-}"; shift 2;;
    --outdir) OUTDIR="${2:-}"; shift 2;;
    *) die "unknown arg: $1";;
  esac
done

[[ -n "$VERSION" ]] || die "missing --version"
[[ -n "${OUTDIR:-}" ]] || OUTDIR="$PWD"
mkdir -p "$OUTDIR"

apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl git \
  dpkg-dev fakeroot
rm -rf /var/lib/apt/lists/*

echo "[*] go: $(go version)"
echo "[*] arch: $(dpkg --print-architecture)"
echo "[*] outdir: $OUTDIR"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SRC="$WORK/src"
ROOT="$WORK/root"
BIN="$WORK/xray"

git clone --depth 1 --branch "v${VERSION}" https://github.com/XTLS/Xray-core.git "$SRC"

COMMIT="$(cd "$SRC" && git rev-parse --short HEAD)"

cd "$SRC"
export CGO_ENABLED=0
go mod download
go build -trimpath -buildvcs=false \
  -ldflags "-s -w -X github.com/xtls/xray-core/core.build=${COMMIT}" \
  -o "$BIN" ./main

mkdir -p "$WORK/resources"
LIST=('Loyalsoldier v2ray-rules-dat geoip geoip' 'Loyalsoldier v2ray-rules-dat geosite geosite')
for i in "${LIST[@]}"
do
  INFO=($(echo $i | awk 'BEGIN{FS=" ";OFS=" "} {print $1,$2,$3,$4}'))
  FILE_NAME="${INFO[3]}.dat"
  HASH="$(curl -sL "https://raw.githubusercontent.com/${INFO[0]}/${INFO[1]}/release/${INFO[2]}.dat.sha256sum" | awk -F ' ' '{print $1}')"
  curl -sL "https://raw.githubusercontent.com/${INFO[0]}/${INFO[1]}/release/${INFO[2]}.dat" -o "$WORK/resources/${FILE_NAME}"
  [ -s "$WORK/resources/${FILE_NAME}" ] || die "${FILE_NAME} download failed/empty"
  [ "$(sha256sum "$WORK/resources/${FILE_NAME}" | awk -F ' ' '{print $1}')" == "${HASH}" ] || die "The HASH key of ${FILE_NAME} does not match cloud one."
done

mkdir -p "$ROOT"/{DEBIAN,usr/bin,etc/xray,lib/systemd/system}
install -m0755 "$BIN" "$ROOT/usr/bin/xray"
install -m0644 "$WORK/resources/geoip.dat" "$ROOT/usr/bin/geoip.dat"
install -m0644 "$WORK/resources/geosite.dat" "$ROOT/usr/bin/geosite.dat"

cat >"$ROOT/etc/xray/config.json" <<'EOF'
{ "log": { "loglevel": "warning" }, "inbounds": [], "outbounds": [] }
EOF

cat >"$ROOT/lib/systemd/system/xray-core.service" <<'EOF'
[Unit]
Description=Xray-core
After=network-online.target

[Service]
ExecStart=/usr/bin/xray run -config /etc/xray/config.json
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

cat >"$ROOT/DEBIAN/control" <<EOF
Package: xray-core
Version: ${VERSION}-${REVISION}
Architecture: $(dpkg --print-architecture)
Maintainer: xray-core-rpm packager
Depends: systemd
Description: Xray-core
EOF

OUTDEB="$OUTDIR/xray-core_${VERSION}-${REVISION}_$(dpkg --print-architecture).deb"
dpkg-deb --build "$ROOT" "$OUTDEB"

ls -la "$OUTDEB"
