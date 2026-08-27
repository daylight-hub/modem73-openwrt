#
# OpenWrt package for MODEM73 (https://github.com/RFnexus/modem73)
# Tested against the OpenWrt 24.10 SDK (gcc 13.3.0 / musl 1.2.5)
#
# This is free software, licensed under the GNU General Public License v2.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=modem73
PKG_VERSION:=2.3.9
PKG_RELEASE:=1

PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://codeload.github.com/RFnexus/modem73/tar.gz/refs/tags/v$(PKG_VERSION)?
PKG_HASH:=ab80ca7b2810dba037b169d7b00064486faef89a2c3172cf8e0f6bebfee78550

PKG_MAINTAINER:=you <you@example.org>
PKG_LICENSE:=Unlicense
PKG_LICENSE_FILES:=LICENSE

PKG_BUILD_PARALLEL:=1
# MIPS16 would cripple the DSP inner loops; make sure it is never used.
PKG_BUILD_FLAGS:=no-mips16

include $(INCLUDE_DIR)/package.mk

define Package/modem73
  SECTION:=net
  CATEGORY:=Network
  TITLE:=OFDM/ROBUST/MFSK software modem with KISS TNC
  URL:=https://modem73.app
  DEPENDS:= \
	+libstdcpp \
	+libncurses \
	+alsa-lib \
	+kmod-usb-audio \
	+MODEM73_CM108:hidapi \
	+MODEM73_CM108:kmod-usb-hid \
	+MODEM73_HAMLIB:libhamlib
endef

define Package/modem73/description
  MODEM73 is a software modem for any HF/VHF/UHF radio with 2400 Hz of
  audio bandwidth. It exposes a KISS-over-TCP interface (default port
  8001) plus a JSON control port (default 8073), so it can back APRS
  clients, packet BBS software, Reticulum and similar.

  On a router you almost certainly want the headless mode driven by the
  bundled procd init script and /etc/config/modem73.

  Requires a USB sound card (kmod-usb-audio) wired to your radio.
  This is a floating-point heavy DSP workload: it needs a hardware FPU
  and a reasonably fast CPU. Soft-float MIPS targets (ath79, ramips)
  will build but will not keep up with real-time audio.
endef

define Package/modem73/config
	config MODEM73_CM108
		bool "Enable CM108 USB PTT support (pulls in hidapi)"
		depends on PACKAGE_modem73
		default y
		help
		  Many cheap USB sound dongles (and the AIOC) expose a
		  CM108-style HID GPIO that can key the radio. Adds ~40 kB
		  plus the hidapi/libusb dependency chain.

	config MODEM73_HAMLIB
		bool "Enable direct Hamlib PTT support (pulls in libhamlib, large)"
		depends on PACKAGE_modem73
		default n
		help
		  Links libhamlib directly instead of talking to a remote
		  rigctld over TCP. libhamlib is several megabytes; on a
		  flash constrained router prefer running rigctld elsewhere
		  and using the --rigctl host:port option.
endef

define Package/modem73/conffiles
/etc/config/modem73
endef

# Upstream hardcodes -march=native, which is meaningless when cross compiling
# and makes gcc emit host instructions. Strip it; the target CPU flags come in
# via TARGET_CXXFLAGS below.
define Build/Configure
	$(SED) 's/-march=native//' $(PKG_BUILD_DIR)/Makefile
endef

# Upstream's Makefile uses `CXXFLAGS = ...` followed by several `+=` lines
# (version define, hidapi and hamlib pkg-config output). Passing CXXFLAGS on
# the make command line would silently discard those appends, so inject the
# toolchain flags through CC/CXX instead.
MAKE_FLAGS += \
	CC="$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_CPPFLAGS)" \
	CXX="$(TARGET_CXX) $(TARGET_CXXFLAGS) $(TARGET_CPPFLAGS) $(TARGET_LDFLAGS)" \
	VERSION="$(PKG_VERSION)"

define Package/modem73/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/modem73 $(1)/usr/bin/modem73

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/modem73.init $(1)/etc/init.d/modem73

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/modem73.config $(1)/etc/config/modem73
endef

$(eval $(call BuildPackage,modem73))
