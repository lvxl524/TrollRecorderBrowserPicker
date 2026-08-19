export TARGET = iphone:clang:latest:15.0
export ARCHS = arm64e
export THEOS_PACKAGE_SCHEME = rootless
include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = TrappPickerPrefs
TrappPickerPrefs_FILES = TrappPickerRootListController.m
TrappPickerPrefs_INSTALL_PATH = /Library/PreferenceLoader/Preferences
TrappPickerPrefs_FRAMEWORKS = UIKit
TrappPickerPrefs_CFLAGS = -fobjc-arc -Wno-error -Wno-unused-variable -Wno-unused-function -Wno-deprecated-declarations -I..
# PSListController is provided at runtime by Preferences.app. Allow all undefined
# symbols to be resolved dynamically at load time. This avoids the fragile
# -Wl,-U,_OBJC_CLASS_$_PSListController escaping dance (the literal $ in the
# symbol name gets eaten by make/shell expansion).
TrappPickerPrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk
