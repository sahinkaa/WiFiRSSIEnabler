THEOS_PACKAGE_SCHEME ?= roothide
ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:16.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WiFiRSSIEnabler
WiFiRSSIEnabler_FILES = WiFiRSSIEnabler.m
WiFiRSSIEnabler_FRAMEWORKS = Foundation UIKit QuartzCore
WiFiRSSIEnabler_LIBRARIES = substrate
WiFiRSSIEnabler_CFLAGS = -fobjc-arc -Wall -Wextra -Werror

include $(THEOS_MAKE_PATH)/tweak.mk
