TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = FindMy

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FindMyHistory
FindMyHistory_FILES = Tweak.xm HistoryVC.mm SettingsVC.mm FMHSettings.mm FMHData.mm
FindMyHistory_CFLAGS = -fobjc-arc
FindMyHistory_LIBRARIES = sqlite3
FindMyHistory_FRAMEWORKS = Foundation UIKit MapKit

include $(THEOS_MAKE_PATH)/tweak.mk
