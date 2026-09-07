import Darwin
import Foundation
import IOKit
import IOKit.ps

public struct TempSensor: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let celsius: Double
    public let group: String        // "CPU", "GPU", "Battery", "System"
}

public struct BatteryInfo: Sendable {
    public var present = false
    public var percent = 0
    public var charging = false
    public var cycleCount = 0
    public var health = ""
    public var timeToEmptyMinutes = -1
}

public struct ThermalReport: Sendable {
    public var sensors: [TempSensor] = []
    public var battery = BatteryInfo()
    /// macOS's own public thermal pressure signal.
    public var thermalState = "Nominal"
    /// Set when the private sensor interface returned nothing on this machine.
    public var sensorsUnavailable = false

    public init() {}

    /// Average of the SoC die sensors — the usable "CPU temperature".
    public var cpuAverage: Double? {
        let c = sensors.filter { $0.group == "SoC" }
        guard !c.isEmpty else { return nil }
        return c.reduce(0.0) { $0 + $1.celsius } / Double(c.count)
    }
    /// Excludes the calibration reference, which reads high by design.
    public var hottest: TempSensor? {
        sensors.filter { $0.group != "Reference" }.max { $0.celsius < $1.celsius }
    }

    public var groups: [String] {
        let order = ["SoC", "GPU", "Storage", "Battery", "System", "Reference"]
        let present = Set(sensors.map { $0.group })
        return order.filter { present.contains($0) }
    }
}

/// Reads on-die temperature sensors.
///
/// There is no public API for this. Apple silicon exposes the sensors through
/// the HID event system (the same path `powermetrics` uses), so we resolve those
/// symbols at runtime with `dlsym` rather than linking against private headers —
/// if a future macOS drops them, the app degrades to "unavailable" instead of
/// failing to launch. `ProcessInfo.thermalState` and the battery figures below
/// are fully public and always work, so the section is never empty.
public final class SensorReader: @unchecked Sendable {

    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatchingFn = @convention(c) (AnyObject, CFDictionary) -> Void
    private typealias CopyServicesFn = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias CopyEventFn = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias FloatValueFn = @convention(c) (AnyObject, Int32) -> Double

    private var handle: UnsafeMutableRawPointer?
    private var create: CreateFn?
    private var setMatching: SetMatchingFn?
    private var copyServices: CopyServicesFn?
    private var copyProperty: CopyPropertyFn?
    private var copyEvent: CopyEventFn?
    private var floatValue: FloatValueFn?
    private var client: AnyObject?

    private static let temperatureEventType: Int64 = 15
    private static let appleVendorUsagePage = 0xff00
    private static let temperatureUsage = 5

    public init() {
        handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
        guard let h = handle else { return }
        func sym<T>(_ n: String, _ t: T.Type) -> T? {
            guard let p = dlsym(h, n) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        create = sym("IOHIDEventSystemClientCreate", CreateFn.self)
        setMatching = sym("IOHIDEventSystemClientSetMatching", SetMatchingFn.self)
        copyServices = sym("IOHIDEventSystemClientCopyServices", CopyServicesFn.self)
        copyProperty = sym("IOHIDServiceClientCopyProperty", CopyPropertyFn.self)
        copyEvent = sym("IOHIDServiceClientCopyEvent", CopyEventFn.self)
        floatValue = sym("IOHIDEventGetFloatValue", FloatValueFn.self)

        if let c = create?(kCFAllocatorDefault)?.takeRetainedValue() {
            client = c
            let match: [String: Any] = [
                "PrimaryUsagePage": Self.appleVendorUsagePage,
                "PrimaryUsage": Self.temperatureUsage
            ]
            setMatching?(c, match as CFDictionary)
        }
    }

    deinit { if let h = handle { dlclose(h) } }

    public func read() -> ThermalReport {
        var r = ThermalReport()
        r.thermalState = Self.thermalStateName()
        r.battery = Self.readBattery()
        r.sensors = readTemperatures()
        r.sensorsUnavailable = r.sensors.isEmpty
        return r
    }

    private func readTemperatures() -> [TempSensor] {
        guard let c = client,
              let servicesRef = copyServices?(c)?.takeRetainedValue(),
              let copyProperty, let copyEvent, let floatValue else { return [] }

        let services = servicesRef as NSArray
        var out: [TempSensor] = []
        // IOHIDEventFieldBase(type) is type << 16.
        let field = Int32(truncatingIfNeeded: Self.temperatureEventType << 16)

        for case let service as AnyObject in services {
            guard let nameRef = copyProperty(service, "Product" as CFString)?.takeRetainedValue(),
                  let name = nameRef as? String else { continue }
            guard let ev = copyEvent(service, Self.temperatureEventType, 0, 0)?.takeRetainedValue()
            else { continue }
            let value = floatValue(ev, field)
            // Filter obvious garbage: a Mac is never at 0 °C or above 130 °C.
            guard value > 1, value < 130 else { continue }
            out.append(TempSensor(name: prettify(name), celsius: value, group: group(for: name)))
        }
        return out.sorted { $0.celsius > $1.celsius }
    }

    /// Apple's sensor names are cryptic ("PMU tdie8", "pACC MTR Temp Sensor1").
    /// On Apple silicon the `tdie` sensors are the SoC die temperatures — the
    /// closest thing this hardware exposes to a "CPU temperature".
    private func prettify(_ raw: String) -> String {
        let parts = raw.split(separator: " ").map(String.init)
        let unit = parts.first ?? raw
        let channel = parts.count > 1 ? parts[1] : ""

        if channel.hasPrefix("tdie") {
            let n = channel.dropFirst(4)
            return n.isEmpty ? "SoC die" : "SoC die \(n)"
        }
        if channel.hasPrefix("tdev") {
            let n = channel.dropFirst(4)
            return n.isEmpty ? "Board" : "Board sensor \(n)"
        }
        if channel == "tcal" { return "Calibration reference\(unit.hasSuffix("2") ? " 2" : "")" }

        return raw
            .replacingOccurrences(of: "MTR Temp Sensor", with: "core ")
            .replacingOccurrences(of: "pACC", with: "Performance CPU")
            .replacingOccurrences(of: "eACC", with: "Efficiency CPU")
            .replacingOccurrences(of: "SOC", with: "SoC")
            .replacingOccurrences(of: "ANE", with: "Neural Engine")
            .replacingOccurrences(of: "NAND", with: "SSD")
            .replacingOccurrences(of: "PMU", with: "Power controller")
            .trimmingCharacters(in: .whitespaces)
    }

    private func group(for raw: String) -> String {
        let u = raw.uppercased()
        if u.contains("TDIE") { return "SoC" }          // die temp = CPU/GPU package
        if u.contains("PACC") || u.contains("EACC") || u.contains("CPU") { return "SoC" }
        if u.contains("GPU") { return "GPU" }
        if u.contains("BATT") || u.contains("GAS GAUGE") { return "Battery" }
        if u.contains("SSD") || u.contains("NAND") { return "Storage" }
        if u.contains("TCAL") { return "Reference" }
        return "System"
    }

    // MARK: Public APIs (always available)

    static func thermalStateName() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return "Nominal"
        case .fair:     return "Fair"
        case .serious:  return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    static func readBattery() -> BatteryInfo {
        var b = BatteryInfo()
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return b }

        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue()
                    as? [String: Any] else { continue }
            b.present = true
            if let cur = d[kIOPSCurrentCapacityKey] as? Int,
               let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 {
                b.percent = Int(Double(cur) / Double(max) * 100)
            }
            b.charging = (d[kIOPSIsChargingKey] as? Bool) ?? false
            if let t = d[kIOPSTimeToEmptyKey] as? Int { b.timeToEmptyMinutes = t }
        }

        // Cycle count and health come from the SMC-backed IORegistry node.
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            if let cc = IORegistryEntryCreateCFProperty(service, "CycleCount" as CFString,
                                                        kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int { b.cycleCount = cc }
            if let design = IORegistryEntryCreateCFProperty(service, "DesignCapacity" as CFString,
                                                            kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int,
               let full = IORegistryEntryCreateCFProperty(service, "AppleRawMaxCapacity" as CFString,
                                                          kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int, design > 0 {
                b.health = "\(Int(Double(full) / Double(design) * 100))%"
            }
        }
        return b
    }
}
