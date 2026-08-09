# Turn snapshots into useful comparisons

Written against: PowerBar initial implementation before repository publication

## Evidence chain

- Surface: `PowerBar/PowerBarView.swift`, Snapshots section
- Problem: the empty state promises comparison over time, but each populated row shows only one isolated reading: percentage, watts, date, and state. The interface never presents a change between snapshots.
- Design evidence: `PowerBar/PowerBarView.swift:241-260` contains the promise and the complete populated-row presentation; `PowerBar/Models.swift:71-79` confirms each snapshot already retains the full reading needed for comparison.
- Owner: `SnapshotsView` with snapshot data from `PowerMonitor.snapshots`
- Scope and affected surfaces: populated and empty snapshot states
- Uncertainty: comparison should remain descriptive when charging state changes because a watt delta across opposite flow directions can mislead

## Design decision

Make the newest snapshot the comparison anchor. Present each older snapshot with elapsed time and battery-level change from the snapshot immediately newer than it. Show watt change only when both readings share the same charging direction. This fulfills the existing comparison promise without adding a chart or inventing trend claims from sparse manual samples.

## Reuse

- `BatterySnapshot.reading`, `BatteryReading.menuBarText`, `BatteryReading.wattsText`, and system `List`
- Exemplar: aligned, monospaced values in `ReadingRow`

## Changes

1. `PowerBar/PowerBarView.swift`, `SnapshotsView`
   - Change: iterate snapshots with their index so a row can compare against the immediately newer snapshot. Keep percentage and watts as the primary line. Make the secondary line show full timestamp plus elapsed interval. Add a trailing signed percentage-point delta for comparable rows; use `Baseline` for the newest or oldest unpaired row as appropriate.
   - Preserve: newest-first order, charging state, battery symbol, and Finder action.
   - Verify: deltas use percentage points, not percent change, and the comparison direction is clear.
2. `PowerBar/Models.swift`
   - Change: add a small `SnapshotComparison` value computed from two snapshots. Return percentage-point delta always when both levels exist, and watt delta only when both readings are charging or both are discharging.
   - Preserve: persisted snapshot schema and backward compatibility with existing JSON.
   - Verify: no migration is required and old snapshots decode unchanged.
3. `PowerBar/PowerBarView.swift`, snapshot actions and empty state
   - Change: retain `Capture Snapshot` as the primary action, use a compact icon-only Finder button with help text once snapshots exist, and change the empty-state description to `Capture two readings to see how level and draw change.`
   - Preserve: capture sound, 50-snapshot limit, and local JSON storage.
   - Verify: the empty state tells the truth and the primary action remains visually dominant.
4. `PowerBarTests/PowerParserTests.swift` or a new `SnapshotComparisonTests.swift`
   - Change: test positive, negative, missing-value, and charging-direction-change comparisons.
   - Preserve: parser-test coverage.
   - Verify: direction changes suppress watt deltas while retaining safe battery-level comparisons.

## Scope

- Inherit: all saved and newly captured snapshots.
- Verify: one snapshot, two snapshots, 50 snapshots, missing watts, missing percentage, charging-to-discharging transition, and long elapsed durations.
- Exclude: automatic sampling, charts, deletion, CSV export, and persistence-format changes.

## Validation

- Product: capture two snapshots and understand the level change and elapsed time directly in the list.
- Interface: verify empty, one-item, two-item, and long-list states at 370 by 520 points.
- System: confirm comparison is derived at presentation time and persisted JSON remains unchanged.
- Repository: `xcodebuild -project PowerBar.xcodeproj -scheme PowerBar -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO` -> all tests pass.

## Stop conditions

- Stop if product intent changes from manual checkpoints to continuous battery history; that requires a separate sampling and charting design rather than overloading snapshots.

## Design documentation

- After acceptance and validation: update the snapshot bullet in `README.md` to state that adjacent manual snapshots show level and same-direction draw changes.
