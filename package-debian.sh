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
    -h|--help)
      cat <<EOF
Usage: $0 --version <x.y.z> [--revision <n>] [--outdir <dir>]
EOF
      exit 0;;
    *) die "unknown arg: $1";;
  esac
done

[[ -n "$VERSION" ]] || die "missing --version"
[[ -n "${OUTDIR:-}" ]] || OUTDIR="$PWD"
mkdir -p "$OUTDIR"

# Align with official Xray-install defaults
LOCAL_PREFIX="/usr/local"
DAT_PATH="${LOCAL_PREFIX}/share/xray"
JSON_PATH="${LOCAL_PREFIX}/etc/xray"

apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl git \
  dpkg-dev fakeroot
rm -rf /var/lib/apt/lists/*

# go is expected to be provided by the container/toolchain in your workflow
command -v go >/dev/null 2>&1 || die "go not found (use actions/setup-go or install golang-go)"
echo "[*] go: $(go version)"
echo "[*] arch: $(dpkg --print-architecture)"
echo "[*] outdir: $OUTDIR"
echo "[*] prefix: $LOCAL_PREFIX"
echo "[*] DAT_PATH: $DAT_PATH"
echo "[*] JSON_PATH: $JSON_PATH"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SRC="$WORK/src"
ROOT="$WORK/root"
BIN="$WORK/xray"

git clone --depth 1 --branch "v${VERSION}" https://github.com/XTLS/Xray-core.git "$SRC"

COMMIT="$(cd "$SRC" && git rev-parse --short HEAD)"
echo "[*] upstream commit: $COMMIT"

cd "$SRC"
export CGO_ENABLED=0
go mod download
go build -trimpath -buildvcs=false \
  -ldflags "-s -w -X github.com/xtls/xray-core/core.build=${COMMIT}" \
  -o "$BIN" ./main

# Download geodata (same source as official script)
mkdir -p "$WORK/resources"
LIST=('Loyalsoldier v2ray-rules-dat geoip geoip' 'Loyalsoldier v2ray-rules-dat geosite geosite')
for i in "${LIST[@]}"; do
  INFO=($(echo $i | awk 'BEGIN{FS=" ";OFS=" "} {print $1,$2,$3,$4}'))
  FILE_NAME="${INFO[3]}.dat"
  HASH="$(curl -sL "https://raw.githubusercontent.com/${INFO[0]}/${INFO[1]}/release/${INFO[2]}.dat.sha256sum" | awk -F ' ' '{print $1}')"
  curl -sL "https://raw.githubusercontent.com/${INFO[0]}/${INFO[1]}/release/${INFO[2]}.dat" -o "$WORK/resources/${FILE_NAME}"
  [ -s "$WORK/resources/${FILE_NAME}" ] || die "${FILE_NAME} download failed/empty"
  [ "$(sha256sum "$WORK/resources/${FILE_NAME}" | awk '{print $1}')" == "${HASH}" ] || die "HASH mismatch for ${FILE_NAME}"
done

# Debian package root
# systemd unit files should be under /lib/systemd/system on Debian
mkdir -p \
  "$ROOT/DEBIAN" \
  "$ROOT${LOCAL_PREFIX}/bin" \
  "$ROOT${DAT_PATH}" \
  "$ROOT${JSON_PATH}" \
  "$ROOT/lib/systemd/system"

# Install files (aligned with official layout)
install -m0755 "$BIN" "$ROOT${LOCAL_PREFIX}/bin/xray"
install -m0644 "$WORK/resources/geoip.dat" "$ROOT${DAT_PATH}/geoip.dat"
install -m0644 "$WORK/resources/geosite.dat" "$ROOT${DAT_PATH}/geosite.dat"

cat >"$ROOT${JSON_PATH}/config.json" <<'EOF'
{ "log": { "loglevel": "warning" }, "inbounds": [], "outbounds": [] }
EOF

# systemd units aligned in NAME with official (service content also aligned)
cat >"$ROOT/lib/systemd/system/xray.service" <<EOF
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

cat >"$ROOT/lib/systemd/system/xray@.service" <<EOF
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

# Optional: maintainer scripts to enable/start like the official install script does
cat >"$ROOT/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload || true
  systemctl enable xray.service >/dev/null 2>&1 || true
  systemctl start xray.service >/dev/null 2>&1 || true
fi
exit 0
EOF
chmod 0755 "$ROOT/DEBIAN/postinst"

cat >"$ROOT/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
if command -v systemctl >/dev/null 2>&1; then
  systemctl stop xray.service >/dev/null 2>&1 || true
fi
exit 0
EOF
chmod 0755 "$ROOT/DEBIAN/prerm"

cat >"$ROOT/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload || true
fi
exit 0
EOF
chmod 0755 "$ROOT/DEBIAN/postrm"

# Control
cat >"$ROOT/DEBIAN/control" <<EOF
Package: xray-core
Version: ${VERSION}-${REVISION}
Architecture: $(dpkg --print-architecture)
Maintainer: xray-core packager
Depends: systemd
Description: Xray-core (layout aligned with official install-release.sh)
EOF

OUTDEB="$OUTDIR/xray-core_${VERSION}-${REVISION}_$(dpkg --print-architecture).deb"
dpkg-deb --build "$ROOT" "$OUTDEB"

ls -la "$OUTDEB"
