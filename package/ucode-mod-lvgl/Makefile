include $(TOPDIR)/rules.mk

PKG_NAME:=ucode-mod-lvgl
PKG_RELEASE:=1

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/blogic/ucode-mod-lvgl.git
PKG_MIRROR_HASH:=96278a9e4d7370c095d4eb9e540d0fb0b56d06f489df61675e23d5e25565d7d8
PKG_SOURCE_DATE:=2026-08-19
PKG_SOURCE_VERSION:=b3ea3d46d5fa0eebeeb80f27b896dcdb3d3bdc77

PKG_BUILD_DEPENDS:=lvgl

PKG_LICENSE:=GPL-2.0-only
PKG_LICENSE_FILES:=LICENSE.txt
PKG_MAINTAINER:=John Crispin <john@phrozen.org>

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/cmake.mk

CMAKE_INSTALL:=1

define Package/ucode-mod-lvgl
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=LVGL module for ucode
  DEPENDS:=+libucode +libubox +libdrm
endef

define Package/ucode-mod-lvgl/description
Binds LVGL to ucode, so a user interface for a small DRM display can be written
in ucode rather than in C. Carries no fonts or images: type and artwork are
loaded at run time from files the application ships, with lv.font_load() and
lv.image_load().
endef

define Package/ucode-mod-lvgl/install
	$(INSTALL_DIR) $(1)/usr/lib/ucode
	$(CP) $(PKG_INSTALL_DIR)/usr/lib/ucode/lv.so $(1)/usr/lib/ucode/
endef

$(eval $(call BuildPackage,ucode-mod-lvgl))
