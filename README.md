# PowerBar

PowerBar is a native macOS menu bar utility for live battery context on a
personal M5 Max MacBook Pro. It is intentionally a focused personal tool, not
a promise of complete hardware coverage for every Mac.

- battery percentage, charging state, time estimate, and a live battery-flow estimate with quieter technical details
- the highest-impact apps and system processes, grouped by owning application and shown as relative energy impact rather than invented watts
- active processes preventing display or system sleep
- recent sleep, wake, power-source, and charge events
- automatic one-minute battery and power-flow history with native 1, 6, and 24-hour charts
- timestamped local snapshots stored as readable JSON, with adjacent level and same-direction draw comparisons
- active USB-C and MagSafe connections, including negotiated charger power, cable power and data ratings, and charging bottleneck diagnostics

The live wattage is calculated from smart-battery voltage × instantaneous current. It describes battery flow, not the power adapter's rated wattage.

## Build and run

Requirements: macOS 14 or later, Xcode, and XcodeGen.

```sh
xcodegen generate
xcodebuild -project PowerBar.xcodeproj -scheme PowerBar -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/PowerBar-*/Build/Products/Debug/PowerBar.app
```

PowerBar is an accessory app, so it appears only in the menu bar. It registers its installed main app to launch at login, refreshes every 15 seconds, records one automatic history sample per minute for 24 hours at `~/Library/Application Support/PowerBar/history.json`, and keeps up to 50 manual snapshots at `~/Library/Application Support/PowerBar/snapshots.json`.

History and snapshots stay local to the Mac. The cable reader is scoped to the
modern Apple HPM controller classes used by the target M5 laptop; other Macs
may still provide battery context but may not expose the full port view.

USB-C port discovery and USB Power Delivery e-marker decoding include adapted
MIT-licensed code from [WhatCable](https://github.com/darrylmorley/whatcable),
pinned to upstream commit `cb778bc52bd304fd640dd767fd2936feeb0f8049`.
See `LICENSES/WhatCable.txt` for attribution.

## Test

```sh
xcodebuild -project PowerBar.xcodeproj -scheme PowerBar -destination 'platform=macOS' test
```

## Releases

Direct distribution uses signed and notarized arm64 ZIPs attached to GitHub
Releases. See [`docs/releasing.md`](docs/releasing.md) for the local and GitHub
Actions release workflow.

## License

PowerBar is released under the MIT License. The cable discovery and USB Power
Delivery e-marker portions adapted from WhatCable retain their separate
attribution in `LICENSES/WhatCable.txt`.
