#!/usr/bin/env bash
#
# Run build.sh inside an emulated x86_64 Debian container.
#
# This exists so you CAN build on an arm64 Raspberry Pi, but understand the
# trade: every instruction of the x86_64 toolchain runs under QEMU emulation.
# Expect a few hours on a Pi 4B, versus ~10 minutes on real x86_64 hardware
# or a GitHub Actions runner. Use this only if you have no other machine.
#
# Requires Docker. On Raspberry Pi OS:
#     sudo apt install -y docker.io
#     sudo usermod -aG docker "$USER"     # then log out and back in

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "docker not found. sudo apt install -y docker.io"

docker info >/dev/null 2>&1 \
	|| die "Cannot talk to the Docker daemon. Add yourself to the 'docker' group
(sudo usermod -aG docker \"$USER\"), log out and back in, or re-run with sudo."

say "Registering QEMU binfmt handlers for x86_64"
docker run --rm --privileged tonistiigi/binfmt --install amd64

say "Starting emulated x86_64 build (this will take hours -- leave it running)"

docker run --rm -i \
	--platform linux/amd64 \
	-v "${HERE}:/src" \
	-w /src \
	debian:bookworm \
	bash -euo pipefail -c '
		echo "container arch: $(uname -m)"

		export DEBIAN_FRONTEND=noninteractive
		apt-get update -qq
		apt-get install -y -qq --no-install-recommends \
			build-essential clang flex bison g++ gawk gettext git \
			libncurses-dev libssl-dev python3-setuptools rsync swig \
			unzip zlib1g-dev file wget zstd ca-certificates sudo

		# The OpenWrt build system refuses to run as root, so build as a
		# normal user that owns the mounted tree.
		useradd -m builder
		chown -R builder /src
		su builder -c "cd /src && ./build.sh"
	'

say "Done -- artifacts are in ${HERE}/out/"
ls -la "${HERE}/out/" 2>/dev/null || true
