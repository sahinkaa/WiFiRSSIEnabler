# WiFi RSSI Enabler

<img src="icon.png" alt="WiFi RSSI Enabler icon" width="144">

WiFi RSSI Enabler replaces the Wi-Fi bars with your iPhone’s RSSI (Received Signal Strength Indicator), a measure of how much Wi-Fi signal power the phone receives from its connected access point. The readout is in dBm, a logarithmic unit referenced to one milliwatt. The status bar shows just the number, so `-34` means **-34 dBm**.

**Closer to zero means a stronger signal.** For example, -50 dBm is stronger than -70 dBm. Watch the number as you move around to spot weak areas or find a better place for your router. RSSI measures signal strength, while download speed depends on other factors too.

Cellular bars stay visible. The RSSI readout follows the system status bar color. Control Center uses 14-point regular on iOS 16. On iOS 26 it matches the carrier font when visible and uses 16-point regular when the carrier label is absent. The supported layouts reserve room next to the VPN badge.

## Installation

Download the matching package from [Releases](https://github.com/sahinkaa/WiFiRSSIEnabler/releases) and respring after installing. Rootless and native RootHide packages target iOS 16 and later.

## Tested devices

- iPhone 8 Plus (non-notched) on iOS 16.6 with Dopamine RootHide
- iPhone 11 Pro Max (notched) on iOS 26.0.1 with Dopamine 3 RootHide

## Build

With Xcode, ldid and Theos configured, run `make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless` for rootless or use `THEOS_PACKAGE_SCHEME=roothide` with RootHide Theos.
