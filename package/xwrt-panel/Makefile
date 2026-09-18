include $(TOPDIR)/rules.mk

PKG_NAME:=xwrt-panel
PKG_VERSION:=1.0.0
PKG_RELEASE:=4

PKG_LICENSE:=Apache-2.0 OFL-1.1
PKG_LICENSE_FILES:=files/usr/share/xwrt-panel/fonts/OFL.txt
PKG_MAINTAINER:=Beaverfffan <1056715226@qq.com>

include $(INCLUDE_DIR)/package.mk

define Package/xwrt-panel
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Minimal statistics panel for the GL-BE10000/BE14000 TFT
  DEPENDS:=+ucode +ucode-mod-lvgl +ucode-mod-ubus +ucode-mod-uloop \
    +ucode-mod-uci +ucode-mod-fs
  PKGARCH:=all
endef

define Package/xwrt-panel/description
 X-Wrt style statistics panel for the 320x240 TFT found on the
 GL-BE10000 and GL-BE14000. Swipeable pages: WAN usage, system,
 clients, ports, WAN interfaces and WiFi. No lock screen, no PIN,
 no weather.

 Self contained: it needs only the generic ucode LVGL binding and
 ships its own Inter font set, so it does not pull in
 glinet-panel-ui, whose ucode UI is meant for the stock firmware.
 If both happen to be installed they are made mutually exclusive,
 because only one process may own the DRM device.
endef

define Build/Compile
endef

define Package/xwrt-panel/install
	$(INSTALL_DIR) $(1)/usr/share/ucode/xwrt-panel
	$(INSTALL_DATA) ./files/usr/share/ucode/xwrt-panel/panel.uc \
		$(1)/usr/share/ucode/xwrt-panel/panel.uc
	$(INSTALL_DIR) $(1)/usr/share/xwrt-panel
	$(INSTALL_DATA) ./files/usr/share/xwrt-panel/xwrt-logo.png \
		$(1)/usr/share/xwrt-panel/xwrt-logo.png
	$(INSTALL_DIR) $(1)/usr/share/xwrt-panel/fonts
	$(INSTALL_DATA) ./files/usr/share/xwrt-panel/fonts/*.bin \
		$(1)/usr/share/xwrt-panel/fonts/
	$(INSTALL_DATA) ./files/usr/share/xwrt-panel/fonts/OFL.txt \
		$(1)/usr/share/xwrt-panel/fonts/
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/xwrt_panel $(1)/etc/config/xwrt_panel
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/xwrt-panel $(1)/etc/init.d/xwrt-panel
endef

define Package/xwrt-panel/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
# glinet-panel-ui and xwrt-panel drive the same display: never run both
if [ -x /etc/init.d/glinet-panel-ui ] && /etc/init.d/glinet-panel-ui enabled; then
	/etc/init.d/glinet-panel-ui stop
	/etc/init.d/glinet-panel-ui disable
	echo "xwrt-panel: glinet-panel-ui stopped and disabled (only one panel can own the display)"
fi
/etc/init.d/xwrt-panel enable
/etc/init.d/xwrt-panel start
exit 0
endef

$(eval $(call BuildPackage,xwrt-panel))
