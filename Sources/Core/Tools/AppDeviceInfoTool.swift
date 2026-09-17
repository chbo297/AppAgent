//
//  AppDeviceInfoTool.swift
//  AppAgent
//
//  Host-environment tool: report device model, OS, storage, memory, locale and
//  power state. This is the structured replacement for the "basic shell commands"
//  idea (uname / df / uptime / date): iOS gives apps no exec, so everything here
//  is read natively and returned as JSON.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

public struct AppDeviceInfoTool: ToolProtocol {
    public let name = "app_device_info"
    public let description = """
        Read the device and runtime environment the host app is running in. \
        Pick a 'section' to keep the payload small, or omit it for everything:
        - 'device': model identifier, simulator flag, screen size and scale.
        - 'os': system name and version, process/system uptime.
        - 'app': bundle id, version, build.
        - 'storage': free/total capacity of the app's volume.
        - 'memory': physical memory and this app's current footprint.
        - 'locale': locale, preferred languages, time zone and UTC offset.
        - 'power': low-power mode, thermal state, battery level and charging state.
        """
    public let parameters = Tool.Schema(
        properties: [
            "section": .string(
                description: "Which slice to report. Omit or use 'all' for everything.",
                enumValues: ["all", "device", "os", "app", "storage", "memory", "locale", "power"]
            )
        ],
        required: []
    )
    public let group = "host-runtime"
    public let safetyLevel: Tool.SafetyLevel = .safe

    public init() {}

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        let section = arguments["section"]?.stringValue ?? "all"
        let known = ["all", "device", "os", "app", "storage", "memory", "locale", "power"]
        guard known.contains(section) else {
            return .error("Unknown section: '\(section)'. Use one of \(known.joined(separator: ", ")).")
        }

        var result: [String: JSONValue] = [:]
        let wantsAll = section == "all"
        if wantsAll || section == "device" { result["device"] = await Self.deviceSection() }
        if wantsAll || section == "os" { result["os"] = Self.osSection() }
        if wantsAll || section == "app" { result["app"] = Self.appSection() }
        if wantsAll || section == "storage" { result["storage"] = Self.storageSection() }
        if wantsAll || section == "memory" { result["memory"] = Self.memorySection() }
        if wantsAll || section == "locale" { result["locale"] = Self.localeSection() }
        if wantsAll || section == "power" { result["power"] = await Self.powerSection() }
        return .json(.object(result))
    }

    // MARK: - Sections

    static func deviceSection() async -> JSONValue {
        var obj: [String: JSONValue] = [:]
        // On a real device hw.machine is the model ("iPhone15,2"); in the simulator it
        // reports the host CPU, so prefer the env var the simulator injects.
        let env = ProcessInfo.processInfo.environment
        if let simulated = env["SIMULATOR_MODEL_IDENTIFIER"] {
            obj["model"] = .string(simulated)
            obj["simulator"] = .bool(true)
        } else {
            obj["model"] = .string(sysctlString("hw.machine") ?? sysctlString("hw.model") ?? "unknown")
            obj["simulator"] = .bool(false)
        }
        obj["cpu_cores"] = .number(Double(ProcessInfo.processInfo.processorCount))

        #if canImport(UIKit) && !os(watchOS)
        let screen = await MainActor.run { () -> [String: JSONValue] in
            let bounds = UIScreen.main.bounds
            return [
                "width": .number(Double(bounds.width)),
                "height": .number(Double(bounds.height)),
                "scale": .number(Double(UIScreen.main.scale))
            ]
        }
        obj["screen"] = .object(screen)
        #endif
        return .object(obj)
    }

    static func osSection() -> JSONValue {
        let info = ProcessInfo.processInfo
        var obj: [String: JSONValue] = [
            "version_string": .string(info.operatingSystemVersionString),
            "system_uptime_seconds": .number(info.systemUptime.rounded())
        ]
        #if os(iOS) || targetEnvironment(macCatalyst)
        obj["name"] = .string("iOS")
        #elseif os(macOS)
        obj["name"] = .string("macOS")
        #endif
        let v = info.operatingSystemVersion
        obj["version"] = .string("\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)")
        return .object(obj)
    }

    static func appSection() -> JSONValue {
        let bundle = Bundle.main
        return .object([
            "bundle_id": .string(bundle.bundleIdentifier ?? "unknown"),
            "version": .string(bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"),
            "build": .string(bundle.infoDictionary?["CFBundleVersion"] as? String ?? "unknown")
        ])
    }

    static func storageSection() -> JSONValue {
        let path = NSHomeDirectory()
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let free = attrs[.systemFreeSize] as? NSNumber,
              let total = attrs[.systemSize] as? NSNumber else {
            return .object(["error": .string("File system attributes unavailable.")])
        }
        return .object([
            "free_bytes": .number(free.doubleValue),
            "total_bytes": .number(total.doubleValue),
            "free_readable": .string(byteString(free.int64Value)),
            "total_readable": .string(byteString(total.int64Value))
        ])
    }

    static func memorySection() -> JSONValue {
        var obj: [String: JSONValue] = [
            "physical_bytes": .number(Double(ProcessInfo.processInfo.physicalMemory)),
            "physical_readable": .string(byteString(Int64(ProcessInfo.processInfo.physicalMemory)))
        ]
        if let footprint = appFootprintBytes() {
            obj["app_footprint_bytes"] = .number(Double(footprint))
            obj["app_footprint_readable"] = .string(byteString(Int64(footprint)))
        }
        return .object(obj)
    }

    static func localeSection() -> JSONValue {
        let zone = TimeZone.current
        return .object([
            "locale": .string(Locale.current.identifier),
            "preferred_languages": .array(Locale.preferredLanguages.prefix(5).map { .string($0) }),
            "time_zone": .string(zone.identifier),
            "utc_offset_seconds": .number(Double(zone.secondsFromGMT())),
            "current_time": .string(ISO8601DateFormatter().string(from: Date()))
        ])
    }

    static func powerSection() async -> JSONValue {
        var obj: [String: JSONValue] = [:]
        #if os(iOS) || targetEnvironment(macCatalyst)
        obj["low_power_mode"] = .bool(ProcessInfo.processInfo.isLowPowerModeEnabled)
        #endif
        obj["thermal_state"] = .string(thermalStateName(ProcessInfo.processInfo.thermalState))

        #if canImport(UIKit) && !os(watchOS) && !targetEnvironment(macCatalyst)
        let battery = await MainActor.run { () -> [String: JSONValue] in
            let device = UIDevice.current
            let wasEnabled = device.isBatteryMonitoringEnabled
            device.isBatteryMonitoringEnabled = true
            defer { device.isBatteryMonitoringEnabled = wasEnabled }
            var values: [String: JSONValue] = ["state": .string(batteryStateName(device.batteryState))]
            // -1 means "unknown"; only report a level we actually got.
            if device.batteryLevel >= 0 {
                values["level"] = .number(Double((device.batteryLevel * 100).rounded()) / 100)
            }
            return values
        }
        obj["battery"] = .object(battery)
        #endif
        return .object(obj)
    }

    // MARK: - Helpers

    /// Read a string sysctl value (e.g. "hw.machine").
    static func sysctlString(_ key: String) -> String? {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer)
        return value.isEmpty ? nil : value
    }

    /// This process's physical footprint — the number Xcode's memory gauge shows.
    static func appFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.phys_footprint
    }

    static func byteString(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    #if canImport(UIKit) && !os(watchOS) && !targetEnvironment(macCatalyst)
    static func batteryStateName(_ state: UIDevice.BatteryState) -> String {
        switch state {
        case .unknown: return "unknown"
        case .unplugged: return "unplugged"
        case .charging: return "charging"
        case .full: return "full"
        @unknown default: return "unknown"
        }
    }
    #endif
}
