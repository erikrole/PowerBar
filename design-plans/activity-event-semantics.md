# Give each power event an honest visual identity

Written against: PowerBar initial implementation before repository publication

## Evidence chain

- Surface: `PowerBar/PowerBarView.swift`, Activity section
- Problem: every event except `Sleep` receives the same yellow sun symbol, including dark wake, connecting to power, switching to battery, and charge changes. The icon contradicts several event titles and prevents quick scanning.
- Design evidence: the event titles produced by `PowerParser.events` reach `PowerEvent.title`; `PowerBar/PowerBarView.swift:181-195` maps only the exact title `Sleep` and assigns the same fallback to every other event.
- Owner: `PowerEvent` presentation in `ActivityView`
- Scope and affected surfaces: Sleep & Wake rows in the Activity section
- Uncertainty: none for the current six event titles

## Design decision

Move event presentation semantics onto `PowerEvent` so each known event type owns a specific SF Symbol and semantic tint. Keep the row layout quiet and native, but make the leading icon accurately distinguish sleep, wake, dark wake, adapter connection, battery use, and charge changes.

## Reuse

- Existing `PowerEvent.title` values and SF Symbols
- Exemplar: `BatteryReading.symbolName`, which already centralizes state-to-symbol mapping in `PowerBar/Models.swift`

## Changes

1. `PowerBar/Models.swift`, `PowerEvent`
   - Change: add computed `symbolName` and `tintRole` presentation properties with exhaustive mappings for `Sleep`, `Wake`, `Dark wake`, `Connected to power`, `Switched to battery`, and `Charge changed`. Use `moon.fill`, `sunrise.fill`, `moon.stars.fill`, `powerplug.fill`, `battery.75percent`, and `arrow.up.arrow.down` respectively. Unknown events use `clock.arrow.circlepath` and secondary styling.
   - Preserve: event identity, date, title, detail, decoding behavior, and parser output.
   - Verify: every current parser title maps deterministically and unknown future titles remain legible.
2. `PowerBar/PowerBarView.swift`, Sleep & Wake row
   - Change: replace the binary `Sleep` conditional with the event-owned symbol and tint. Promote the event title to `.subheadline.weight(.medium)`, keep date at caption size, and keep raw detail at caption with two-line truncation.
   - Preserve: current ordering, relative date, detail text, and section structure.
   - Verify: icon and title agree for all current event types and rows scan without relying on color alone.
3. `PowerBarTests/PowerParserTests.swift`
   - Change: add assertions covering the symbol mapping for each parser-generated event title plus the unknown fallback.
   - Preserve: existing parser tests.
   - Verify: test failures identify any future title that silently loses its intended visual semantics.

## Scope

- Inherit: every Sleep & Wake row generated from `PowerParser.events`.
- Verify: light mode, dark mode, monochrome/increased contrast, and mixed event lists.
- Exclude: assertion icons, parser event detection, event ordering, and new event categories.

## Validation

- Product: open Activity and identify sleep, wake, source changes, and charge changes by icon and title without reading raw details.
- Interface: verify all six known states, unknown fallback, long details, and missing dates.
- System: confirm presentation mapping has one owner in `PowerEvent` and the view contains no duplicated title switch.
- Repository: `xcodebuild -project PowerBar.xcodeproj -scheme PowerBar -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO` -> all tests pass.

## Stop conditions

- Stop if SF Symbol availability conflicts with the macOS 27 deployment target; substitute only with a symbol confirmed available on macOS 27.

## Design documentation

- After acceptance and validation: none.
