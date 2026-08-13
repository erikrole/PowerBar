import XCTest
@testable import PowerBar

final class CableStatusTests: XCTestCase {
    func testDecodesStandardFiveAmpCable() {
        let value = UInt32(0b11)
            | UInt32(0b10 << 5)

        let decoded = CableDataSource.decodeCableVDO(value, isActive: false)

        XCTAssertEqual(decoded.maximumWatts, 100)
        XCTAssertEqual(decoded.speed, .fortyGbps)
    }

    func testDecodesEPRCableAtUSBPDLimit() {
        let value = UInt32(0b100)
            | UInt32(0b10 << 5)
            | UInt32(0b11 << 9)

        let decoded = CableDataSource.decodeCableVDO(value, isActive: true)

        XCTAssertEqual(decoded.maximumWatts, 240)
        XCTAssertEqual(decoded.speed, .eightyGbps)
    }

    func testCableLimitTakesPriorityOverCurrentChargeState() {
        let diagnostic = CableDiagnostic(
            negotiatedWatts: 60,
            chargerWatts: 96,
            cableWatts: 60,
            hasExternalPower: true,
            isCharging: true,
            isFullyCharged: false,
            transportText: "USB2"
        )

        XCTAssertEqual(diagnostic.title, "Cable is limiting charging speed")
        XCTAssertEqual(diagnostic.severity, .warning)
    }

    func testLowerNegotiationIsInformational() {
        let diagnostic = CableDiagnostic(
            negotiatedWatts: 30,
            chargerWatts: 96,
            cableWatts: 100,
            hasExternalPower: true,
            isCharging: true,
            isFullyCharged: false,
            transportText: nil
        )

        XCTAssertEqual(diagnostic.title, "Charging at 30 W")
        XCTAssertEqual(diagnostic.severity, .informational)
    }

    func testMatchedPowerUsesNeutralConnectedLanguage() {
        let diagnostic = CableDiagnostic(
            negotiatedWatts: 94,
            chargerWatts: 96,
            cableWatts: 100,
            hasExternalPower: true,
            isCharging: true,
            isFullyCharged: false,
            transportText: nil
        )

        XCTAssertEqual(diagnostic.title, "Power connected · up to 94 W")
        XCTAssertEqual(diagnostic.severity, .normal)
    }

    func testFullBatteryUsesAConciseReadyState() {
        let diagnostic = CableDiagnostic(
            negotiatedWatts: 140,
            chargerWatts: 140,
            cableWatts: nil,
            hasExternalPower: true,
            isCharging: false,
            isFullyCharged: true,
            transportText: nil
        )

        XCTAssertEqual(diagnostic.title, "Fully charged")
        XCTAssertEqual(
            diagnostic.detail,
            "Plugged in and running on external power. Charging will resume when needed."
        )
        XCTAssertEqual(diagnostic.severity, .normal)
    }

    func testPausedChargingUsesPluggedInLanguage() {
        let diagnostic = CableDiagnostic(
            negotiatedWatts: 96,
            chargerWatts: 96,
            cableWatts: nil,
            hasExternalPower: true,
            isCharging: false,
            isFullyCharged: false,
            transportText: nil
        )

        XCTAssertEqual(diagnostic.title, "Charging paused")
        XCTAssertEqual(diagnostic.detail, "Plugged in. macOS has paused battery charging for now.")
        XCTAssertEqual(diagnostic.severity, .informational)
    }

    func testPrimaryPowerPortPrefersNegotiatedContract() {
        let display = CablePort(
            typeCode: 2,
            number: 1,
            typeName: "USB-C",
            isConnected: true,
            transports: ["DisplayPort"],
            negotiatedWatts: nil,
            chargerWatts: nil,
            cableWatts: nil,
            cableSpeed: nil
        )
        let charger = CablePort(
            typeCode: 2,
            number: 2,
            typeName: "USB-C",
            isConnected: true,
            transports: ["USB2"],
            negotiatedWatts: 96,
            chargerWatts: 96,
            cableWatts: 100,
            cableSpeed: .usb2
        )

        let status = CableStatus(ports: [display, charger], adapterWatts: 96)

        XCTAssertEqual(status.primaryPowerPort?.id, charger.id)
    }

    func testBatteryPowerSuppressesStaleChargingWarning() {
        let diagnostic = CableDiagnostic(
            negotiatedWatts: 60,
            chargerWatts: 140,
            cableWatts: 60,
            hasExternalPower: false,
            isCharging: false,
            isFullyCharged: false,
            transportText: "USB4"
        )

        XCTAssertEqual(diagnostic.title, "Connected via USB4")
        XCTAssertEqual(diagnostic.detail, "No charging contract is active on this port.")
        XCTAssertEqual(diagnostic.severity, .normal)
    }

    func testM5Type10USBPortFixture() throws {
        let port = try XCTUnwrap(CableDataSource.parsePort(properties: [
            "PortTypeDescription": "USB-C",
            "PortNumber": 4,
            "PortType": 2,
            "ConnectionActive": true,
            "TransportsActive": ["CIO", "USB4"],
        ]))

        XCTAssertEqual(CableDataSource.portClasses, [
            "AppleTCControllerType10",
            "AppleTCControllerType11",
            "AppleHPMInterfaceType10",
            "AppleHPMInterfaceType11",
        ])
        XCTAssertEqual(port, RawPort(
            typeCode: 2,
            number: 4,
            typeName: "USB-C",
            isConnected: true,
            transports: ["CIO", "USB4"]
        ))
    }

    func testM5Type11MagSafeFixtureUsesLocationFallback() throws {
        let port = try XCTUnwrap(CableDataSource.parsePort(
            properties: [
                "PortTypeDescription": "MagSafe 3",
                "ConnectionActive": true,
                "TransportsActive": [],
            ],
            locationNumber: 1
        ))

        XCTAssertEqual(port.typeCode, 0x11)
        XCTAssertEqual(port.number, 1)
        XCTAssertEqual(port.typeName, "MagSafe 3")
    }

    func testSystemAdapterReadingIsNeverGuessedOntoOnlyConnectedPort() {
        let status = CableDataSource.makeStatus(
            ports: [RawPort(
                typeCode: 2,
                number: 4,
                typeName: "USB-C",
                isConnected: true,
                transports: ["USB4"]
            )],
            sources: [],
            cables: [],
            adapterWatts: 140
        )

        XCTAssertEqual(status.adapterWatts, 140)
        XCTAssertNil(status.ports.first?.chargerWatts)
        XCTAssertNil(status.primaryPowerPort)
    }

    func testTransientIOKitFailureKeepsRecentReadingWhileOnACPower() {
        let capturedAt = Date(timeIntervalSince1970: 1_000)
        let previous = CableStatus(
            ports: [.fixture],
            adapterWatts: 140
        )
        var battery = BatteryReading.empty
        battery.powerSource = "AC Power"

        let resolution = CableStatusPolicy.resolve(
            incoming: .empty,
            previous: previous,
            battery: battery,
            lastReliableAt: capturedAt,
            now: capturedAt.addingTimeInterval(15)
        )

        XCTAssertEqual(resolution.status, previous)
        XCTAssertEqual(resolution.lastReliableAt, capturedAt)
    }

    func testBatteryPowerClearsUnavailableCableReadingImmediately() {
        let capturedAt = Date(timeIntervalSince1970: 1_000)
        let previous = CableStatus(
            ports: [.fixture],
            adapterWatts: 140
        )
        var battery = BatteryReading.empty
        battery.powerSource = "Battery Power"

        let resolution = CableStatusPolicy.resolve(
            incoming: .empty,
            previous: previous,
            battery: battery,
            lastReliableAt: capturedAt,
            now: capturedAt.addingTimeInterval(1)
        )

        XCTAssertEqual(resolution.status, .empty)
        XCTAssertNil(resolution.lastReliableAt)
    }

    func testTransientIOKitReadingExpiresAfterGracePeriod() {
        let capturedAt = Date(timeIntervalSince1970: 1_000)
        let previous = CableStatus(
            ports: [.fixture],
            adapterWatts: 140
        )
        var battery = BatteryReading.empty
        battery.powerSource = "AC Power"

        let resolution = CableStatusPolicy.resolve(
            incoming: .empty,
            previous: previous,
            battery: battery,
            lastReliableAt: capturedAt,
            now: capturedAt.addingTimeInterval(31)
        )

        XCTAssertEqual(resolution.status, .empty)
        XCTAssertNil(resolution.lastReliableAt)
    }

    func testCableConnectionChangeIncludesSpeedAndPower() {
        let current = CableStatus(ports: [.fixture], adapterWatts: 140)

        let changes = CableConnectionChange.changes(from: CableStatus(), to: current)
        var battery = BatteryReading.empty
        battery.powerSource = "AC Power"

        XCTAssertEqual(changes, [.connected(.fixture)])
        XCTAssertEqual(changes.first?.title, "USB-C Port 4 connected")
        XCTAssertEqual(
            changes.first?.notificationBody(battery: battery),
            "USB4 · 80 Gbps · 240 W cable · 94 W power available"
        )
    }

    func testCableDisconnectUsesLastKnownCapabilities() {
        let previous = CableStatus(ports: [.fixture], adapterWatts: 140)
        var battery = BatteryReading.empty
        battery.percentage = 82
        battery.powerSource = "Battery Power"

        let changes = CableConnectionChange.changes(from: previous, to: CableStatus())

        XCTAssertEqual(changes, [.disconnected(.fixture)])
        XCTAssertEqual(changes.first?.title, "USB-C Port 4 disconnected")
        XCTAssertEqual(
            changes.first?.notificationBody(battery: battery),
            "Running on battery · 82%"
        )
    }

    func testCableCapabilityRefreshDoesNotRepeatConnectionNotification() {
        let preliminary = CablePort(
            typeCode: 2,
            number: 4,
            typeName: "USB-C",
            isConnected: true,
            transports: ["USB4"],
            negotiatedWatts: nil,
            chargerWatts: nil,
            cableWatts: nil,
            cableSpeed: nil
        )

        let changes = CableConnectionChange.changes(
            from: CableStatus(ports: [preliminary]),
            to: CableStatus(ports: [.fixture])
        )

        XCTAssertTrue(changes.isEmpty)
    }

    func testUnavailableCableStatusNeverCreatesConnectionChanges() {
        let connected = CableStatus(ports: [.fixture])

        XCTAssertTrue(CableConnectionChange.changes(from: .empty, to: connected).isEmpty)
        XCTAssertTrue(CableConnectionChange.changes(from: connected, to: .empty).isEmpty)
    }

    func testNotificationStateReprimesAfterUnavailableSample() {
        var state = CableNotificationState()
        let connected = CableStatus(ports: [.fixture])

        state.prime(with: connected)
        XCTAssertTrue(state.changes(for: .empty).isEmpty)
        XCTAssertTrue(state.changes(for: connected).isEmpty)
        XCTAssertEqual(state.changes(for: CableStatus()), [.disconnected(.fixture)])
    }
}

private extension CablePort {
    static let fixture = CablePort(
        typeCode: 2,
        number: 4,
        typeName: "USB-C",
        isConnected: true,
        transports: ["USB4"],
        negotiatedWatts: 94,
        chargerWatts: 140,
        cableWatts: 240,
        cableSpeed: .eightyGbps
    )
}
