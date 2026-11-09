# WiFi RSSI Enabler

<img src="icon.png" alt="WiFi RSSI Enabler icon" width="144">

Replace the Wi-Fi bars in the status bar with the connected network’s signal strength as a white number, such as `-34`. Cellular bars stay visible. On iOS 26, the Control Center readout matches the carrier label’s typography when available.

## Installation

Download the matching package from [Releases](https://github.com/sahinkaa/WiFiRSSIEnabler/releases) and respring after installing. Tested on iOS 16.6 and iOS 26.0.1 with RootHide. The rootless build targets iOS 16 and later and has been checked on the build host.

## Build

With Xcode, ldid and Theos configured, run `make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless` for rootless or use `THEOS_PACKAGE_SCHEME=roothide` with RootHide Theos.
