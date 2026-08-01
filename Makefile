# FilzaBookmarkFix — repair Filza bookmarks broken by roothide's moving jbroot.
#
# Build: export THEOS=~/theos && make clean && make package
#
# Target: iPhone 14 Pro Max (A16, arm64e) on iOS 16.3.1, Dopamine/Roothide.
# ARCHS MUST include arm64e — ElleKit silently skips arm64-only dylibs on A12+.
# THEOS_PACKAGE_SCHEME = rootless produces the iphoneos-arm64 deb Patcher wants.

TARGET = iphone:clang:14.5:14.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = Filza

TWEAK_NAME = FilzaBookmarkFix

FilzaBookmarkFix_FILES = FilzaBookmarkFix.m
FilzaBookmarkFix_CFLAGS = -fobjc-arc
FilzaBookmarkFix_FRAMEWORKS = Foundation

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
