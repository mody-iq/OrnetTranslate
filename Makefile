export THEOS_PACKAGE_SCHEME = roothide

TARGET := iphone:clang:latest:16.0
ARCHS = arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = OrnetTranslate

OrnetTranslate_FILES = Tweak.xm
OrnetTranslate_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
OrnetTranslate_FRAMEWORKS = UIKit WebKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
