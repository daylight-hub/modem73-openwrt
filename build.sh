#!/usr/bin/env bash
#
# Build the modem73 package for OpenWrt 24.10.2 on Raspberry Pi 4B
# (target bcm27xx/bcm2711, package arch aarch64_cortex-a72).
#
# Usage:
#   ./build.sh              # download SDK, build, collect .ipk files
#   ./build.sh --clean      # also wipe a previous SDK extraction
#
# Everything happens under ./work/ ; nothing is installed on your system.

set -euo pipefail

RELEASE="24.10.2"
TARGET="bcm27xx"
SUBTARGET="bcm2711"
PKG_ARCH="aarch64_cortex-a72"

BASE_URL="https://downloads.openwrt.org/releases/${RELEASE}/targets/${TARGET}/${SUBTARGET}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${HERE}/work"
OUT="${HERE}/out"
JOBS="$(nproc 2>/dev/null || echo 4)"

say()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- host deps --

say "Checking host build dependencies"

MISSING=()
for t in wget tar zstd git make gcc g++ python3 file rsync unzip patch which gawk; do
	command -v "$t" >/dev/null 2>&1 || MISSING+=("$t")
done

# Header-only checks the SDK will need later.
[ -e /usr/include/ncurses.h ] || [ -e /usr/include/ncursesw/ncurses.h ] || MISSING+=("libncurses-dev")
[ -e /usr/include/zlib.h ] || MISSING+=("zlib1g-dev")
[ -e /usr/include/openssl/ssl.h ] || MISSING+=("libssl-dev")

if [ "${#MISSING[@]}" -gt 0 ]; then
	warn "Missing: ${MISSING[*]}"
	cat >&2 <<'EOF'

On Debian/Ubuntu install them with:

  sudo apt update && sudo apt install -y build-essential clang flex bison g++ \
      gawk gettext git libncurses-dev libssl-dev python3-setuptools rsync \
      swig unzip zlib1g-dev file wget zstd

EOF
	die "Install the missing packages and re-run."
fi

if [ "${1:-}" = "--clean" ]; then
	say "Removing previous work directory"
	rm -rf "$WORK"
fi

# Fail here rather than after a 200 MB download.
if [ ! -f "${HERE}/modem73/Makefile" ]; then
	warn "Package sources not found at ${HERE}/modem73/"
	cat >&2 <<EOF

build.sh needs the package directory sitting next to it:

    ${HERE}/
      build.sh
      modem73/
        Makefile
        files/modem73.init
        files/modem73.config

Extract the full modem73-openwrt archive and run build.sh from inside it,
rather than copying build.sh out on its own.

EOF
	die "Missing package sources."
fi

mkdir -p "$WORK" "$OUT"
cd "$WORK"

# ------------------------------------------------------------------- fetch ---

say "Fetching checksum list from ${BASE_URL}"
wget -q -O sha256sums "${BASE_URL}/sha256sums" \
	|| die "Could not reach ${BASE_URL}. Check the release/target still exist."

# The SDK toolchain is prebuilt for a specific HOST architecture. Pick the
# matching one rather than assuming x86_64 -- running an x86_64 SDK on an
# arm64 machine fails much later with an opaque "cannot execute binary file".
HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
	x86_64|amd64)  SDK_HOST="Linux-x86_64"  ;;
	aarch64|arm64) SDK_HOST="Linux-aarch64" ;;
	*)             SDK_HOST="Linux-${HOST_ARCH}" ;;
esac

say "Host architecture: ${HOST_ARCH} -> looking for ${SDK_HOST} SDK"

ALL_SDKS="$(awk '{print $2}' sha256sums | tr -d '*' | grep -E '^openwrt-sdk-' || true)"

# NOTE: the '|| true' matters. Under 'set -euo pipefail' a grep that matches
# nothing returns 1, which aborts the whole script at this assignment -- before
# the helpful diagnostics below ever run.
SDK_TAR="$(printf '%s\n' "$ALL_SDKS" \
	| grep -E "${SDK_HOST}\.tar\.(zst|xz)\$" | head -1 || true)"

if [ -z "$SDK_TAR" ]; then
	warn "No SDK published for host architecture ${HOST_ARCH}."
	echo >&2
	echo "SDKs available for ${TARGET}/${SUBTARGET}:" >&2
	if [ -n "$ALL_SDKS" ]; then
		printf '      %s\n' $ALL_SDKS >&2
	else
		echo "      (none listed?!)" >&2
	fi
	cat >&2 <<'EOF'

The OpenWrt buildbot publishes x86_64 host SDKs only. "Cross compiling for
the Pi" does not mean building ON a Pi: the SDK ships a prebuilt x86_64
compiler, and there is no arm64 build of it.

Three ways forward, best first:

  1. GitHub Actions -- free x86_64 runners, ~10 minutes, no local hardware.
     Push this directory to a GitHub repo; a ready-made workflow is included
     at .github/workflows/build-openwrt.yml. Run it, download the artifact.

  2. Any x86_64 Linux machine (laptop, desktop, VM, cloud box). Copy this
     directory over and run ./build.sh there.

  3. Emulated x86_64 container on this Pi -- works unattended but is SLOW
     (hours, not minutes). See ./build-docker.sh.

In all three cases the OUTPUT is identical: an aarch64_cortex-a72 .ipk that
you scp to the OpenWrt Pi and install with opkg.

EOF
	die "Cannot build on this host."
fi

say "SDK: ${SDK_TAR}"

if [ ! -f "$SDK_TAR" ]; then
	wget --show-progress -q -O "$SDK_TAR" "${BASE_URL}/${SDK_TAR}" \
		|| die "SDK download failed."
else
	say "Already downloaded, skipping"
fi

say "Verifying checksum"
# OpenWrt's sha256sums uses binary-mode format: "<hash> *<filename>".
# Compare hashes directly rather than feeding a reconstructed line to
# 'sha256sum -c', which is fussy about that leading asterisk.
EXPECTED="$(awk -v f="$SDK_TAR" '{ n=$2; sub(/^\*/,"",n); if (n==f) print $1 }' sha256sums)"
[ -n "$EXPECTED" ] || die "No checksum listed for ${SDK_TAR} in sha256sums."

ACTUAL="$(sha256sum "$SDK_TAR" | awk '{print $1}')"

if [ "$EXPECTED" != "$ACTUAL" ]; then
	warn "expected: ${EXPECTED}"
	warn "actual:   ${ACTUAL}"
	die "Checksum mismatch — delete work/${SDK_TAR} and retry."
fi
say "Checksum OK"

SDK_DIR="${SDK_TAR%.tar.zst}"; SDK_DIR="${SDK_DIR%.tar.xz}"

if [ ! -d "$SDK_DIR" ]; then
	say "Extracting"
	case "$SDK_TAR" in
		*.zst) tar --zstd -xf "$SDK_TAR" ;;
		*.xz)  tar -xJf "$SDK_TAR" ;;
	esac
fi

cd "$SDK_DIR"

# ------------------------------------------------------------------ package --

say "Installing modem73 package into the SDK tree"
rm -rf package/modem73
cp -r "${HERE}/modem73" package/modem73

# ------------------------------------------------------- missing base pkgs --
# The SDK ships a TRIMMED copy of the base package tree. Two packages modem73
# needs are absent: libs/ncurses (which also provides the libtinfo.a stub that
# upstream's '-ltinfo' resolves against) and libs/libusb (required by hidapi
# for CM108 PTT). They are not in any feed either, so recover them from
# openwrt.git at the matching release tag.
say "Checking for base packages the SDK omits"

MISSING_BASE=""
for p in package/libs/ncurses package/libs/libusb; do
	[ -d "$p" ] || MISSING_BASE="$MISSING_BASE $p"
done

if [ -n "$MISSING_BASE" ]; then
	warn "SDK is missing:${MISSING_BASE}"
	say "Fetching them from openwrt.git v${RELEASE}"

	rm -rf "${WORK}/openwrt-base"
	git clone --depth 1 --branch "v${RELEASE}" --filter=blob:none --sparse \
		https://github.com/openwrt/openwrt.git "${WORK}/openwrt-base" >/dev/null 2>&1 \
		|| die "Could not clone openwrt.git to recover the missing base packages."

	# shellcheck disable=SC2086
	( cd "${WORK}/openwrt-base" && git sparse-checkout set $MISSING_BASE ) >/dev/null 2>&1 \
		|| die "sparse-checkout of the missing base packages failed."

	for p in $MISSING_BASE; do
		[ -d "${WORK}/openwrt-base/$p" ] \
			|| die "$p is not present in openwrt.git v${RELEASE}."
		mkdir -p "$(dirname "$p")"
		cp -r "${WORK}/openwrt-base/$p" "$(dirname "$p")/"
		say "  added $p"
	done
else
	say "All required base packages already present"
fi

say "Updating package feed"
# Only the 'packages' feed is needed: alsa-lib, hidapi, hamlib and
# libudev-zero all live there. libusb-1.0 is in the base tree. Skipping
# luci/routing/telephony saves several minutes of cloning per run.
if ! ./scripts/feeds update packages >/dev/null 2>&1; then
	warn "Targeted feed update failed, falling back to updating all feeds"
	./scripts/feeds update -a >/dev/null
fi
./scripts/feeds install alsa-lib hidapi hamlib >/dev/null

# ------------------------------------------------------------------- config --

say "Configuring"
make defconfig >/dev/null

{
	echo "CONFIG_PACKAGE_modem73=m"
	# CM108 USB PTT on by default; flip to "# CONFIG_MODEM73_CM108 is not set"
	# if you only use rigctl/VOX/serial and want a smaller install.
	echo "CONFIG_MODEM73_CM108=y"
	echo "# CONFIG_MODEM73_HAMLIB is not set"
} >> .config

make defconfig >/dev/null

grep -q '^CONFIG_PACKAGE_modem73=m' .config \
	|| die "modem73 did not survive defconfig — a dependency is unavailable.
Run 'make menuconfig' in ${WORK}/${SDK_DIR} and look under Network -> modem73."

# -------------------------------------------------------------------- build --

say "Building with ${JOBS} jobs (first run also builds libncurses/hidapi)"
if ! make package/modem73/compile -j"${JOBS}"; then
	warn "Parallel build failed; retrying serially with verbose output"
	make package/modem73/compile -j1 V=s
fi

# ------------------------------------------------------------------ collect --

say "Collecting packages"
find bin/packages -name '*.ipk' -exec cp -f {} "$OUT"/ \;

MAIN="$(find "$OUT" -name 'modem73_*.ipk' | head -1)"
[ -n "$MAIN" ] || die "Build finished but no modem73 .ipk was produced."

case "$(basename "$MAIN")" in
	*"${PKG_ARCH}"*)
		say "Architecture check OK (${PKG_ARCH})" ;;
	*)
		warn "Built package is not ${PKG_ARCH}: $(basename "$MAIN")"
		warn "It will not install on a Pi 4B. Did you edit TARGET/SUBTARGET?" ;;
esac

say "Done"
echo
echo "  Main package:  ${MAIN}"
echo "  All artifacts: ${OUT}/"
echo
ls -la "$OUT"
cat <<EOF

Next steps
----------

  scp ${OUT}/$(basename "$MAIN") root@<pi>:/tmp/
  ssh root@<pi>
  opkg update
  opkg install /tmp/$(basename "$MAIN")

opkg will pull alsa-lib, libncurses, terminfo, libstdcpp and kmod-usb-audio
from the official ${RELEASE} repo. Prefer that over installing the copies in
out/ -- they are the same sources but the official ones are what the rest of
your system is built against.

Only if the Pi has no internet: copy the whole out/ directory over and
'opkg install ./*.ipk'. Note that kmod-usb-audio is NOT in out/ (the SDK
cannot build kernel modules); grab it from the repo or the ImageBuilder.

EOF
