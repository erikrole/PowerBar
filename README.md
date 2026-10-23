# PowerBar

**Retired October 23, 2026.** Development and new releases have ended, and this
repository is archived. [0.1.1 (build 5)](https://github.com/erikrole/PowerBar/releases/tag/v0.1.1)
is the final release and requires macOS 27 or later. Existing downloads and source
history are retained. The instructions below describe the archived implementation.

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

The popover keeps its daily workflow to three tabs: Power for live flow and
cable details, Charge for the current level, draw, holds, and recent events,
and Usage for significant energy consumers. Battery history and manual
snapshots remain available from the overflow menu.

The live wattage is calculated from smart-battery voltage × instantaneous current. It describes battery flow, not the power adapter's rated wattage.

## Build and run

Requirements: macOS 27 or later, Xcode 27 or later, and XcodeGen.

For an unsigned local contributor build:

```sh
xcodegen generate
xcodebuild -project PowerBar.xcodeproj -scheme PowerBar -configuration Debug CODE_SIGNING_ALLOWED=NO build
open ~/Library/Developer/Xcode/DerivedData/PowerBar-*/Build/Products/Debug/PowerBar.app
```

For a signed development launch, open the generated project in Xcode, configure
a development team, and run the PowerBar scheme.

PowerBar is an accessory app, so it appears only in the menu bar. Its Launch at Login setting follows the user’s saved choice, battery status refreshes every 15 seconds, and process-energy sampling runs only while the popover is open. PowerBar records one automatic history sample per minute for 24 hours at `~/Library/Application Support/PowerBar/history.json` and keeps up to 50 manual snapshots at `~/Library/Application Support/PowerBar/snapshots.json`.

History and snapshots stay local to the Mac. The cable reader is scoped to the
modern Apple HPM controller classes used by the target M5 laptop; other Macs
may still provide battery context but may not expose the full port view.

USB-C port discovery and USB Power Delivery e-marker decoding include adapted
MIT-licensed code from [WhatCable](https://github.com/darrylmorley/whatcable),
pinned to upstream commit `cb778bc52bd304fd640dd767fd2936feeb0f8049`.
See `LICENSES/WhatCable.txt` for attribution.

## Test

Contributor tests can run without a signing identity:

```sh
xcodebuild -project PowerBar.xcodeproj -scheme PowerBar -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

## Releases

The final signed and notarized arm64 ZIP remains attached to GitHub Releases.
GitHub Actions workflows are disabled. [`docs/releasing.md`](docs/releasing.md)
preserves the historical release procedure.

## License

PowerBar is released under the MIT License. The cable discovery and USB Power
Delivery e-marker portions adapted from WhatCable retain their separate
attribution in `LICENSES/WhatCable.txt`.

## App updates

AppUpdater checks [erikrole/PowerBar](https://github.com/erikrole/PowerBar/releases) for signed ZIP releases. Normal Release launches check automatically; tests and helper/command launches skip automatic checks. Use **Check for Updates…** in the popover settings menu.

`project.yml` pins the public [AppUpdater](https://github.com/erikrole/AppUpdater) package to `5b5a9411078b79ad92e36bf9d965ecd94b66b420`; rerun XcodeGen after changing the pin. Keep package resolution checked in. App and package targets require **macOS 27**. The host retains its save and busy checks during updater relaunch; no forced-exit fallback is configured.

Published on October 23, 2026 as [PowerBar 0.1.1](https://github.com/erikrole/PowerBar/releases/tag/v0.1.1), build 5, from source `5b4877daeba861155c347da0542cabcd09fff0ec`. The Apple Silicon ZIP requires macOS 27 or later and is Developer ID signed, notarized, and stapled. A SHA-256 checksum and provenance manifest are attached to the release.
