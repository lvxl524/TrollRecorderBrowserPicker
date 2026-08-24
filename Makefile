export TARGET = iphone:clang:latest:15.0
export ARCHS = arm64e
export THEOS_PACKAGE_SCHEME = rootless

INSTALL_TARGET_PROCESSES = TrollRecorder

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TrollRecorderBrowserPicker TRPInterceptor
TrollRecorderBrowserPicker_FILES = Tweak.xm
TrollRecorderBrowserPicker_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-nullability-completeness -Wno-error=nonnull -Wno-error -Wno-unused-variable -Wno-unused-function
TrollRecorderBrowserPicker_FRAMEWORKS = UIKit AuthenticationServices

TRPInterceptor_FILES = Interceptor.xm
TRPInterceptor_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-error -Wno-unused-variable -Wno-unused-function
TRPInterceptor_FRAMEWORKS = UIKit

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += trapppickerprefs
include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	install.exec "killall -9 TrollRecorder 2>/dev/null || true"
