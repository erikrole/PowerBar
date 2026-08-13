import Foundation
import IOKit
import IOKit.ps

// The IOKit discovery and USB-PD e-marker decoding in this file are adapted
// from WhatCable by Darryl Morley at commit
// cb778bc52bd304fd640dd767fd2936feeb0f8049, used under the MIT License.
// https://github.com/darrylmorley/whatcable/tree/cb778bc52bd304fd640dd767fd2936feeb0f8049

enum CableDataSource {
    // Controller class names vary by Mac and macOS build. The owner's M5 Max
    // currently publishes USB-C and MagSafe through AppleTCControllerType10/11,
    // while other current systems expose the equivalent HPM interface classes.
    // Registry-entry IDs are deduplicated when a service matches more than one.
    static let portClasses = [
        "AppleTCControllerType10",
        "AppleTCControllerType11",
        "AppleHPMInterfaceType10",
        "AppleHPMInterfaceType11",
    ]

    static let identityClasses = [
        "IOPortTransportComponentCCUSBPDSOPp",
        "IOPortTransportComponentCCUSBPDSOPpp",
    ]

    static func load() async -> CableStatus {
        await Task.detached(priority: .utility) {
            readStatus()
        }.value
    }

    private static func readStatus() -> CableStatus {
        makeStatus(
            ports: readPorts(),
            sources: readPowerSources(),
            cables: readCableCapabilities(),
            adapterWatts: readAdapterWatts()
        )
    }

    static func makeStatus(
        ports rawPorts: [RawPort],
        sources: [RawPowerSource],
        cables: [RawCableCapability],
        adapterWatts: Int?
    ) -> CableStatus {
        var ports = rawPorts.map { port in
            let matches = sources.filter { $0.portKey == port.portKey }
            let source = preferredSource(in: matches)
            let cable = cables.first { $0.portKey == port.portKey }
            return CablePort(
                typeCode: port.typeCode,
                number: port.number,
                typeName: port.typeName,
                isConnected: port.isConnected,
                transports: port.transports,
                negotiatedWatts: source?.winningWatts,
                chargerWatts: source?.maximumWatts,
                cableWatts: cable?.maximumWatts,
                cableSpeed: cable?.speed
            )
        }

        ports.sort {
            if $0.isConnected != $1.isConnected { return $0.isConnected }
            if $0.typeCode != $1.typeCode { return $0.typeCode < $1.typeCode }
            return $0.number < $1.number
        }
        return CableStatus(
            ports: ports,
            adapterWatts: adapterWatts,
            isAvailable: !rawPorts.isEmpty
        )
    }

    private static func readPorts() -> [RawPort] {
        var ports: [RawPort] = []
        var seen: Set<UInt64> = []
        for className in portClasses {
            forEachService(matching: className) { service in
                var entryID: UInt64 = 0
                guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS,
                      seen.insert(entryID).inserted else { return }

                let read = propertyReader(for: service)
                var properties: [String: Any] = [:]
                for key in [
                    "PortTypeDescription",
                    "PortNumber",
                    "PortType",
                    "ConnectionActive",
                    "TransportsActive",
                ] {
                    if let value = read(key) { properties[key] = value }
                }
                guard let port = parsePort(
                    properties: properties,
                    locationNumber: serviceLocationNumber(service)
                ) else { return }
                ports.append(port)
            }
        }
        return ports
    }

    static func parsePort(properties: [String: Any], locationNumber: Int? = nil) -> RawPort? {
        guard let typeName = properties["PortTypeDescription"] as? String,
              typeName == "USB-C" || typeName.hasPrefix("MagSafe") else { return nil }

        let number = integer(properties["PortNumber"]) ?? locationNumber ?? 0
        guard number > 0 else { return nil }
        let reportedType = integer(properties["PortType"])
        return RawPort(
            typeCode: typeName.hasPrefix("MagSafe") ? 0x11 : (reportedType ?? 0x2),
            number: number,
            typeName: typeName,
            isConnected: boolean(properties["ConnectionActive"]) ?? false,
            transports: stringArray(properties["TransportsActive"])
        )
    }

    private static func readPowerSources() -> [RawPowerSource] {
        var sources: [RawPowerSource] = []
        forEachService(matching: "IOPortFeaturePowerSource") { service in
            let read = propertyReader(for: service)
            let identity = parentPortIdentity(read: read)
            guard identity.number > 0 else { return }
            let options = powerOptions(read("PowerSourceOptions"))
            let winning = powerOption(read("WinningPowerSourceOption"))
            sources.append(RawPowerSource(
                name: read("PowerSourceName") as? String ?? "Unknown",
                typeCode: identity.type,
                number: identity.number,
                maximumWatts: options.map(\.watts).max() ?? winning?.watts,
                winningWatts: winning?.watts
            ))
        }
        return sources
    }

    private static func readCableCapabilities() -> [RawCableCapability] {
        var capabilities: [RawCableCapability] = []
        for className in identityClasses {
            forEachService(matching: className) { service in
                let read = propertyReader(for: service)
                let identity = parentPortIdentity(read: read)
                guard identity.number > 0,
                      let metadata = dictionary(read("Metadata")),
                      let values = metadata["VDOs"] as? NSArray else { return }
                let vdos = values.compactMap { value -> UInt32? in
                    guard let data = value as? Data, data.count >= 4 else { return nil }
                    return data.withUnsafeBytes { bytes in
                        bytes.loadUnaligned(as: UInt32.self).littleEndian
                    }
                }
                guard vdos.count > 3 else { return }
                let header = vdos[0]
                let productType = Int((header >> 27) & 0b111)
                let isActive = productType == 4
                let decoded = decodeCableVDO(vdos[3], isActive: isActive)
                capabilities.append(RawCableCapability(
                    typeCode: identity.type,
                    number: identity.number,
                    maximumWatts: decoded.maximumWatts,
                    speed: decoded.speed
                ))
            }
        }
        return capabilities
    }

    static func decodeCableVDO(_ value: UInt32, isActive: Bool) -> (maximumWatts: Int, speed: CableSpeed?) {
        let speed = CableSpeed(rawValue: Int(value & 0b111))
        let currentBits = Int((value >> 5) & 0b11)
        let amps = currentBits == 2 ? 5 : 3
        let maximumVoltageBits = Int((value >> 9) & 0b11)
        let volts = maximumVoltageBits == 3 ? 48 : 20
        return (volts * amps, speed)
    }

    private static func preferredSource(in sources: [RawPowerSource]) -> RawPowerSource? {
        let priorities = ["USB-PD", "Brick ID", "TypeC"]
        for name in priorities {
            if let source = sources.first(where: { $0.name == name && ($0.winningWatts ?? 0) > 0 }) {
                return source
            }
        }
        for name in priorities {
            if let source = sources.first(where: { $0.name == name }) { return source }
        }
        return sources.first
    }

    private static func readAdapterWatts() -> Int? {
        guard let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return integer(details["Watts"])
    }

    private static func forEachService(matching className: String, body: (io_service_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching(className),
            &iterator
        ) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            body(service)
            IOObjectRelease(service)
        }
    }

    private static func propertyReader(for service: io_service_t) -> (String) -> Any? {
        { key in
            IORegistryEntryCreateCFProperty(
                service,
                key as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue()
        }
    }

    private static func parentPortIdentity(read: (String) -> Any?) -> (type: Int, number: Int) {
        let type = integer(read("ParentBuiltInPortType"))
            ?? integer(read("ParentPortType"))
            ?? 0
        let priority = (read("Priority") as? NSNumber)?.uint64Value ?? 0
        let number = integer(read("ParentBuiltInPortNumber"))
            ?? integer(read("ParentPortNumber"))
            ?? Int(priority & 0xFF)
        return (type, number)
    }

    private static func powerOptions(_ value: Any?) -> [RawPowerOption] {
        let values: [Any]
        if let set = value as? NSSet {
            values = set.allObjects
        } else if let array = value as? NSArray {
            values = array.compactMap { $0 }
        } else {
            return []
        }
        return values.compactMap(powerOption)
    }

    private static func powerOption(_ value: Any?) -> RawPowerOption? {
        guard let values = dictionary(value) else { return nil }
        let voltage = integer(values["Voltage (mV)"]) ?? 0
        let current = integer(values["Max Current (mA)"]) ?? 0
        let milliwatts = integer(values["Max Power (mW)"]) ?? (voltage * current / 1000)
        guard voltage > 0, milliwatts > 0 else { return nil }
        return RawPowerOption(watts: Int((Double(milliwatts) / 1000).rounded()))
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? {
        if let dictionary = value as? [String: Any] { return dictionary }
        guard let dictionary = value as? NSDictionary else { return nil }
        var result: [String: Any] = [:]
        for case let (key, value) as (String, Any) in dictionary {
            result[key] = value
        }
        return result
    }

    private static func integer(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private static func boolean(_ value: Any?) -> Bool? {
        (value as? NSNumber)?.boolValue
    }

    private static func stringArray(_ value: Any?) -> [String] {
        if let array = value as? [String] { return array }
        if let array = value as? NSArray { return array.compactMap { $0 as? String } }
        if let set = value as? NSSet { return set.compactMap { $0 as? String } }
        return []
    }

    private static func serviceLocationNumber(_ service: io_service_t) -> Int? {
        var buffer = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetLocationInPlane(service, kIOServicePlane, &buffer) == KERN_SUCCESS else {
            return nil
        }
        let location = buffer.withUnsafeBytes { bytes in
            String(
                decodingCString: bytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                as: UTF8.self
            )
        }
        return Int(location)
    }
}

struct RawPort: Equatable {
    let typeCode: Int
    let number: Int
    let typeName: String
    let isConnected: Bool
    let transports: [String]
    var portKey: String { "\(typeCode)/\(number)" }
}

struct RawPowerSource: Equatable {
    let name: String
    let typeCode: Int
    let number: Int
    let maximumWatts: Int?
    let winningWatts: Int?
    var portKey: String { "\(typeCode)/\(number)" }
}

private struct RawPowerOption {
    let watts: Int
}

struct RawCableCapability: Equatable {
    let typeCode: Int
    let number: Int
    let maximumWatts: Int
    let speed: CableSpeed?
    var portKey: String { "\(typeCode)/\(number)" }
}
