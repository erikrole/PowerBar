import XCTest
@testable import PowerBar

final class PowerParserTests: XCTestCase {
    func testMenuBarPresentationTracksBatteryLevelAndChargingState() {
        let discharging = BatteryReading(percentage: 47)
        let charging = BatteryReading(percentage: 82, isCharging: true)

        XCTAssertEqual(discharging.menuBarText, "47%")
        XCTAssertEqual(discharging.symbolName, "battery.50percent")
        XCTAssertEqual(charging.menuBarText, "82%")
        XCTAssertEqual(charging.symbolName, "battery.75percent.bolt")
        XCTAssertEqual(BatteryReading.empty.menuBarText, "—")
    }

    func testTemperatureUsesFahrenheitAndFriendlyThresholds() {
        let normal = BatteryReading(temperatureCelsius: 30)
        let warning = BatteryReading(temperatureCelsius: 40)
        let alert = BatteryReading(temperatureCelsius: 46)

        XCTAssertEqual(normal.temperatureText, "86.0 °F")
        XCTAssertEqual(normal.temperatureStatus, .normal)
        XCTAssertEqual(warning.temperatureStatus, .warning)
        XCTAssertEqual(alert.temperatureStatus, .alert)
    }

    func testCommandRunnerDrainsLargeOutput() async throws {
        let result = try await CommandRunner.run("/usr/bin/seq", ["1", "100000"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.hasSuffix("100000\n"))
    }

    func testParsesDischargingBatteryAndSignedAmperage() {
        let pmset = """
        Now drawing from 'Battery Power'
         -InternalBattery-0 (id=1)\t59%; discharging; 2:21 remaining present: true
        """
        let ioreg = """
          \"Voltage\" = 11426
          \"InstantAmperage\" = 18446744073709549399
          \"Temperature\" = 3089
          \"CycleCount\" = 655
          \"MaxCapacity\" = 100
          \"IsCharging\" = No
          \"FullyCharged\" = No
        """

        let reading = PowerParser.battery(pmset: pmset, ioreg: ioreg)

        XCTAssertEqual(reading.percentage, 59)
        XCTAssertEqual(reading.state, "discharging")
        XCTAssertEqual(reading.estimate, "2:21")
        XCTAssertEqual(reading.powerSource, "Battery Power")
        XCTAssertFalse(reading.isCharging)
        XCTAssertEqual(reading.amperageMilliamps, -2217)
        XCTAssertEqual(reading.estimatedWatts ?? 0, -25.331_442, accuracy: 0.000_001)
        XCTAssertEqual(reading.temperatureCelsius ?? 0, 30.89, accuracy: 0.001)
    }

    func testParsesAssertions() {
        let input = #"""
          pid 96138(Claude): [0x0000c8e100019a73] 26:59:13 NoIdleSleepAssertion named: "Electron"
          pid 3312(zen): [0x0001f00500059e42] 00:00:03 NoDisplaySleepAssertion named: "video-playing"
        """#

        let assertions = PowerParser.assertions(input)

        XCTAssertEqual(assertions.count, 2)
        guard assertions.count == 2 else { return }
        XCTAssertEqual(assertions[0].process, "Claude")
        XCTAssertEqual(assertions[0].kind, "Keeps Mac awake")
        XCTAssertEqual(assertions[0].age, "26:59:13")
        XCTAssertEqual(assertions[1].kind, "Keeps display awake")
    }

    func testParsesRecentEventsNewestFirst() {
        let input = """
        2026-08-08 10:00:00 -0500 Using Batt
        2026-08-08 11:00:00 -0500 Entering Sleep state due to 'Idle Sleep'
        2026-08-08 12:00:00 -0500 Wake from Normal Sleep
        """

        let events = PowerParser.events(input)

        XCTAssertEqual(events.map(\.title), ["Wake", "Sleep", "Switched to battery"])
        XCTAssertNotNil(events.first?.date)
    }

    func testGroupsPowerConsumersByOwningApplication() {
        let top = """
        Processes: 100 total
        PID    COMMAND          %CPU POWER
        3329   Zen GPU Helper   24.7 24.7
        3337   plugin-container 28.7 28.7
        77239  After Effects    12.3 12.3
        83005  top              10.6 10.6
        129    powerd           4.0  4.0
        """
        let processes = """
        3329 /Applications/Zen.app/Contents/MacOS/gpu-helper.app/Contents/MacOS/Zen GPU Helper
        3337 /Applications/Zen.app/Contents/MacOS/plugin-container.app/Contents/MacOS/plugin-container
        77239 /Applications/Adobe After Effects 2026/Adobe After Effects 2026.app/Contents/MacOS/After Effects
        83005 /usr/bin/top
        129 /System/Library/CoreServices/powerd.bundle/powerd
        """

        let consumers = PowerParser.consumers(top: top, processes: processes)

        XCTAssertEqual(consumers.map(\.name), ["Zen", "Adobe After Effects 2026", "powerd"])
        XCTAssertEqual(consumers[0].powerScore, 53.4, accuracy: 0.001)
        XCTAssertEqual(consumers[0].cpuPercentage, 53.4, accuracy: 0.001)
        XCTAssertEqual(consumers[0].processCount, 2)
        XCTAssertTrue(consumers[0].isApplication)
        XCTAssertFalse(consumers[2].isApplication)
        XCTAssertEqual(consumers[2].displayName, "Power management")
        XCTAssertEqual(consumers[2].explanation, "Coordinates charging, sleep, and energy policy.")
    }

    func testPowerEventPresentationMappings() {
        let input = """
        2026-08-08 07:00:00 -0500 Entering Sleep state due to 'Idle Sleep'
        2026-08-08 08:00:00 -0500 Wake from Normal Sleep
        2026-08-08 09:00:00 -0500 DarkWake from Normal Sleep
        2026-08-08 10:00:00 -0500 Using AC
        2026-08-08 11:00:00 -0500 Using Batt
        2026-08-08 12:00:00 -0500 Charge: 50
        """
        let eventsByTitle = Dictionary(uniqueKeysWithValues: PowerParser.events(input).map { ($0.title, $0) })
        let expected: [(String, String, PowerEvent.TintRole)] = [
            ("Sleep", "moon.fill", .indigo),
            ("Wake", "sunrise.fill", .orange),
            ("Dark wake", "moon.stars.fill", .indigo),
            ("Connected to power", "powerplug.fill", .green),
            ("Switched to battery", "battery.75percent", .primary),
            ("Charge changed", "arrow.up.arrow.down", .blue),
        ]

        for (title, symbol, tint) in expected {
            XCTAssertEqual(eventsByTitle[title]?.symbolName, symbol, title)
            XCTAssertEqual(eventsByTitle[title]?.tintRole, tint, title)
        }

        let unknown = PowerEvent(id: "future", date: nil, title: "Future event", detail: "")
        XCTAssertEqual(unknown.symbolName, "clock.arrow.circlepath")
        XCTAssertEqual(unknown.tintRole, .secondary)
    }

    func testSnapshotComparisonTracksLevelAndSameDirectionWatts() {
        let older = snapshot(at: 0, percentage: 60, watts: -20, isCharging: false)
        let newer = snapshot(at: 600, percentage: 57, watts: -24.5, isCharging: false)

        let comparison = SnapshotComparison(older: older, newer: newer)

        XCTAssertEqual(comparison.percentagePointDelta, -3)
        XCTAssertEqual(comparison.wattDelta ?? 0, -4.5, accuracy: 0.001)
        XCTAssertEqual(comparison.elapsed, 600)
    }

    func testSnapshotComparisonTracksPositiveChanges() {
        let older = snapshot(at: 0, percentage: 40, watts: 18, isCharging: true)
        let newer = snapshot(at: 300, percentage: 44, watts: 21, isCharging: true)

        let comparison = SnapshotComparison(older: older, newer: newer)

        XCTAssertEqual(comparison.percentagePointDelta, 4)
        XCTAssertEqual(comparison.wattDelta ?? 0, 3, accuracy: 0.001)
    }

    func testSnapshotComparisonHandlesMissingValues() {
        let older = snapshot(at: 0, percentage: nil, watts: nil, isCharging: false)
        let newer = snapshot(at: 60, percentage: 50, watts: -10, isCharging: false)

        let comparison = SnapshotComparison(older: older, newer: newer)

        XCTAssertNil(comparison.percentagePointDelta)
        XCTAssertNil(comparison.wattDelta)
    }

    func testSnapshotComparisonSuppressesWattsWhenDirectionChanges() {
        let older = snapshot(at: 0, percentage: 50, watts: -12, isCharging: false)
        let newer = snapshot(at: 120, percentage: 51, watts: 18, isCharging: true)

        let comparison = SnapshotComparison(older: older, newer: newer)

        XCTAssertEqual(comparison.percentagePointDelta, 1)
        XCTAssertNil(comparison.wattDelta)
    }

    func testHistoryPolicyFiltersAndSortsSamples() {
        let now = Date(timeIntervalSince1970: 100_000)
        let recent = historySample(at: now.addingTimeInterval(-120), percentage: 49)
        let newest = historySample(at: now, percentage: 48)
        let old = historySample(at: now.addingTimeInterval(-7_200), percentage: 60)

        let filtered = BatteryHistoryPolicy.filtered([newest, old, recent], range: .oneHour, now: now)

        XCTAssertEqual(filtered, [recent, newest])
    }

    func testHistoryPolicyRetainsOnlyTwentyFourHours() {
        let now = Date(timeIntervalSince1970: 200_000)
        let boundary = historySample(at: now.addingTimeInterval(-BatteryHistoryPolicy.retentionInterval), percentage: 50)
        let expired = historySample(at: boundary.capturedAt.addingTimeInterval(-1), percentage: 51)

        XCTAssertEqual(BatteryHistoryPolicy.samplesToKeep([expired, boundary], now: now), [boundary])
    }

    private func snapshot(
        at offset: TimeInterval,
        percentage: Int?,
        watts: Double?,
        isCharging: Bool
    ) -> BatterySnapshot {
        BatterySnapshot(reading: BatteryReading(
            capturedAt: Date(timeIntervalSince1970: offset),
            percentage: percentage,
            estimatedWatts: watts,
            isCharging: isCharging
        ))
    }

    private func historySample(at date: Date, percentage: Int) -> BatteryHistorySample {
        BatteryHistorySample(reading: BatteryReading(capturedAt: date, percentage: percentage))
    }
}
