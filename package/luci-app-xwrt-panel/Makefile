include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI support for the xwrt-panel statistics screen
LUCI_DESCRIPTION:=Control the minimal statistics panel on the \
 GL-BE10000 / GL-BE14000 TFT: brightness, page rotation, screen \
 blanking, page selection and service state.
LUCI_DEPENDS:=+luci-base +xwrt-panel
LUCI_PKGARCH:=all

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=Beaverfffan <1056715226@qq.com>

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
