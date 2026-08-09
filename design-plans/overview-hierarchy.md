# Make the live power story immediate

Written against: PowerBar initial implementation before repository publication

## Evidence chain

- Surface: `PowerBar/PowerBarView.swift`, Overview section
- Problem: the header already presents power source and remaining time, then the Overview repeats remaining time in a full metric card and power source again in the battery card. The duplicate facts consume most of the first viewport while the unique live-power reading competes at equal visual weight.
- Design evidence: `PowerBar/PowerBarView.swift:55-67`, `PowerBar/PowerBarView.swift:111-115`, and `PowerBar/PowerBarView.swift:127-151`
- Owner: `OverviewView` and `PowerBarView.header`
- Scope and affected surfaces: the popover header and Overview section only
- Uncertainty: validate the final density at the current 370 by 520 point popover size and with unavailable values

## Design decision

Make the header the single owner of battery level, state, source, and time. Make Overview answer the next question, "what is the battery doing right now?", with one wide live-power hero followed by a quieter technical-details group. Remove repeated source and time values from Overview.

## Reuse

- `BatteryReading.wattsText`, `BatteryReading.wattDirection`, `ReadingRow`, system semantic colors, `.regularMaterial`, and `.numericText()`
- Exemplar: the existing battery-level hierarchy in `PowerBarView.header`

## Changes

1. `PowerBar/PowerBarView.swift`, `PowerBarView.header`
   - Change: preserve the percentage and state title; format the secondary line as source followed by a concise, labeled estimate such as `Battery Power · 2h 21m left` or `Power Adapter · 38m to full`. Keep refresh as the trailing toolbar action.
   - Preserve: battery symbol, charging and low-level semantic color, manual refresh, loading state, and accessibility label.
   - Verify: source and estimate appear exactly once in the Overview task and remain understandable when either value is unavailable.
2. `PowerBar/PowerBarView.swift`, `OverviewView`
   - Change: replace the two equal `MetricCard` instances with one full-width live-power hero. Use a small `LIVE POWER` label, a prominent monospaced-digit watt value, the flow direction, and a subdued bolt symbol. Keep the technical caveat directly below the watt value inside the same surface.
   - Preserve: the disclosure that wattage is an instantaneous battery-flow estimate, not adapter wattage.
   - Verify: live watts are the strongest value after battery percentage and do not truncate at the existing width.
3. `PowerBar/PowerBarView.swift`, Overview battery details
   - Change: rename the group `DETAILS`, remove the duplicate power-source row, and retain voltage, current, temperature, cycle count, and maximum capacity as aligned rows with monospaced numeric values.
   - Preserve: current units and unavailable-value behavior.
   - Verify: every remaining row adds information not already presented in the header or live-power hero.

## Scope

- Inherit: light mode, dark mode, increased contrast, reduced transparency, and all live battery states through system materials and semantic styles.
- Verify: charging, discharging, fully charged, low battery, unavailable estimate, and initial loading.
- Exclude: new data sources, charting, settings, snapshot behavior, and Activity content.

## Validation

- Product: open the popover and answer battery level, state, source, time, and live power without encountering a repeated value.
- Interface: check 0%, 9%, 100%, charging, no estimate, no watt reading, a long source name, light mode, dark mode, and increased contrast.
- System: confirm there is one owner for header context and one owner for technical details; do not introduce another card-style modifier.
- Repository: `xcodebuild -project PowerBar.xcodeproj -scheme PowerBar -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO` -> all tests pass.

## Stop conditions

- Stop if runtime inspection shows the header cannot fit the labeled time estimate without truncation at 370 points; revise the secondary line before widening the popover.

## Design documentation

- After acceptance and validation: record in `README.md` that Overview prioritizes live flow and keeps technical details secondary.
