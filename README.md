# modem73 for OpenWrt 24.10.2 on Raspberry Pi 4B

An OpenWrt package for [MODEM73](https://github.com/RFnexus/modem73) v2.3.9,
targeting `bcm27xx/bcm2711` (package arch `aarch64_cortex-a72`).

```
build.sh                     one-command SDK build
modem73/Makefile             the OpenWrt package
modem73/files/modem73.init   procd init script
modem73/files/modem73.config UCI defaults -> /etc/config/modem73
```

## Build

```sh
./build.sh
```

That downloads the 24.10.2 SDK for bcm2711, verifies its checksum against the
official `sha256sums`, installs the feeds, builds, and drops the result in
`out/`. First run takes a while because it also builds libncurses and hidapi;
later runs reuse `work/`.

Host packages needed (Debian/Ubuntu):

```sh
sudo apt update && sudo apt install -y build-essential clang flex bison g++ \
    gawk gettext git libncurses-dev libssl-dev python3-setuptools rsync \
    swig unzip zlib1g-dev file wget zstd
```

The script checks for these and tells you what's missing before doing anything.

## Install

```sh
scp out/modem73_2.3.9-1_aarch64_cortex-a72.ipk root@<pi>:/tmp/
ssh root@<pi>
opkg update
opkg install /tmp/modem73_2.3.9-1_aarch64_cortex-a72.ipk
```

Let `opkg` pull `alsa-lib`, `libncurses`, `terminfo`, `libstdcpp` and
`kmod-usb-audio` from the official 24.10.2 repo rather than using the copies
in `out/`. They are the same sources, but the official builds are what the
rest of your system is linked against. `kmod-usb-audio` isn't in `out/` at
all — the SDK can't build kernel modules.

## Set up

Plug in the USB sound card and confirm the kernel found it:

```sh
dmesg | grep -i -E 'audio|snd'
ls /dev/snd/
modem73 --list-audio
```

Then edit `/etc/config/modem73`. At minimum set `callsign`, `device`, your PTT
method, and flip `enabled` to `1`:

```sh
/etc/init.d/modem73 enable
/etc/init.d/modem73 start
logread -f -e modem73
```

The init script always runs `--headless`. For the TUI, stop the service and run
`modem73` by hand over SSH — set `TERM=xterm-256color` first, because OpenWrt's
`terminfo` package ships only a small subset of entries (no `xterm-kitty`, no
`putty`).

Settings changed inside the TUI or over the control port save to
`/root/.config/modem73/settings`, which is *separate* from the UCI file. The
init script passes everything on the command line, so UCI wins for the service.
Pick one and stick to it.

## Pi 4B notes

The hardware is a good fit. `bcm27xx` declares both `fpu` and `audio` in its
target features, so there's a real FPU and ALSA is available. Four Cortex-A72
cores at 1.5 GHz is comfortably ahead of the Pi Zero 2 that upstream calls out
as only managing one decoder family at a time, so the shipped config leaves all
three receivers on. If you do run short of CPU, `no_mfsk_rx` and `no_robust_rx`
in the UCI file turn off the families you aren't using. You can't disable the
family you're transmitting with — that flag is ignored.

Storage is a non-issue on SD. The install is roughly 2.5 MB: a ~1.3 MB binary
plus libstdcpp, libncurses/terminfo and alsa-lib. Runtime is 2.3 MB of static
BSS plus audio and decoder buffers.

Two build options are exposed in `make menuconfig` under Network → modem73:

- **CM108 USB PTT** (default on) — pulls in hidapi/libusb. Covers cheap USB
  sound dongles and the AIOC. Turn it off if you use rigctl, VOX or serial PTT.
- **Direct Hamlib PTT** (default off) — links libhamlib, which is several MB.
  Running `rigctld` elsewhere and pointing at it with `--rigctl host:4532` is
  usually the better trade.

## How the package handles upstream's Makefile

Two things needed work:

1. `CXXFLAGS` hardcodes `-march=native`, meaningless when cross compiling.
   `Build/Configure` seds it out; target CPU flags arrive via `TARGET_CXXFLAGS`.
2. Upstream sets `CXXFLAGS`/`LDFLAGS` with `=` and then appends to them with
   `+=` — the version define and the hidapi/hamlib `pkg-config` output. Passing
   `CXXFLAGS=` on the make command line would silently discard every one of
   those appends, so the toolchain flags go in through `CC`/`CXX` instead.

`-ltinfo` and `-ldl` in upstream's link line both resolve without patching:
OpenWrt's ncurses package installs an empty `libtinfo.a` as a compatibility
stub, and musl ships an empty `libdl.a` for the same reason. alsa-lib is a
runtime-only dependency, because miniaudio `dlopen`s `libasound.so.2` rather
than linking it.

## Bumping the version

Change `PKG_VERSION` in `modem73/Makefile`, then get the new hash:

```sh
cd work/openwrt-sdk-*/
make package/modem73/download V=s      # prints the expected hash on mismatch
```

and update `PKG_HASH`.
