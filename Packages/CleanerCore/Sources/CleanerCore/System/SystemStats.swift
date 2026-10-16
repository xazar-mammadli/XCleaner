import Darwin
import Foundation
import IOKit.ps

/// How the Mac's memory is used, in the terms Activity Monitor uses.
public struct MemoryUsage: Sendable, Equatable {
    public enum Pressure: Sendable {
        case normal, warning, critical
    }

    public let totalBytes: UInt64
    /// Memory apps hold on to themselves.
    public let appBytes: UInt64
    /// Memory the system keeps for itself and that can't be moved out.
    public let wiredBytes: UInt64
    /// Memory squeezed in place to make room.
    public let compressedBytes: UInt64
    /// Recently used files kept around; macOS hands this out again as soon as anything needs it.
    public let cachedBytes: UInt64
    public let pressure: Pressure

    /// App, wired and compressed memory: what Activity Monitor calls "Memory Used".
    public var usedBytes: UInt64 { min(totalBytes, appBytes + wiredBytes + compressedBytes) }
}

/// Processor tick counters. Two readings give the load in between.
public struct ProcessorTicks: Sendable, Equatable {
    public let busy: UInt64
    public let idle: UInt64

    /// The share of time the processor was busy since `earlier`, from 0 to 1.
    public func load(since earlier: ProcessorTicks) -> Double {
        let busy = self.busy &- earlier.busy
        let total = busy &+ (idle &- earlier.idle)
        return total > 0 ? Double(busy) / Double(total) : 0
    }
}

/// Bytes that went in and out over Wi-Fi and Ethernet. Two readings give the traffic in between.
public struct NetworkCounters: Sendable, Equatable {
    struct Interface: Sendable, Equatable {
        let received: UInt32
        let sent: UInt32
    }

    let interfaces: [String: Interface]

    /// Bytes moved since `earlier`. The counters are 32-bit and wrap around; between two close readings that is
    /// harmless, since wrapping subtraction still gives the difference.
    public func bytes(since earlier: NetworkCounters) -> (received: UInt64, sent: UInt64) {
        var received: UInt64 = 0
        var sent: UInt64 = 0
        for (name, now) in interfaces {
            guard let before = earlier.interfaces[name] else { continue }
            received += UInt64(now.received &- before.received)
            sent += UInt64(now.sent &- before.sent)
        }
        return (received, sent)
    }
}

public struct BatteryStatus: Sendable, Equatable {
    /// From 0 to 1.
    public let level: Double
    public let isCharging: Bool
    public let isOnPowerAdapter: Bool
    /// Time left on battery, once macOS has worked it out.
    public let minutesLeft: Int?
}

/// System-wide numbers that need no special permission.
public enum SystemStats {
    private static let host = mach_host_self()

    public static func memory() -> MemoryUsage? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(getpagesize())
        let anonymous = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        return MemoryUsage(
            totalBytes: ProcessInfo.processInfo.physicalMemory,
            appBytes: (anonymous - min(purgeable, anonymous)) * page,
            wiredBytes: UInt64(stats.wire_count) * page,
            compressedBytes: UInt64(stats.compressor_page_count) * page,
            cachedBytes: (UInt64(stats.external_page_count) + purgeable) * page,
            pressure: memoryPressure()
        )
    }

    public static func processorTicks() -> ProcessorTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = info.cpu_ticks
        // The order is user, system, idle, nice.
        return ProcessorTicks(busy: UInt64(ticks.0) + UInt64(ticks.1) + UInt64(ticks.3), idle: UInt64(ticks.2))
    }

    /// Counts Wi-Fi and Ethernet (`en…`) only: a VPN's tunnel carries the same traffic again, and loopback never leaves the Mac.
    public static func networkCounters() -> NetworkCounters {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return NetworkCounters(interfaces: [:]) }
        defer { freeifaddrs(first) }
        var interfaces: [String: NetworkCounters.Interface] = [:]
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("en"), entry.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  let data = entry.pointee.ifa_data
            else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            interfaces[name] = .init(received: stats.ifi_ibytes, sent: stats.ifi_obytes)
        }
        return NetworkCounters(interfaces: interfaces)
    }

    /// The built-in battery, or `nil` on a Mac without one.
    public static func battery() -> BatteryStatus? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            // The keys are IOKit's (IOPSKeys.h).
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description["Type"] as? String == "InternalBattery",
                  let current = description["Current Capacity"] as? Int,
                  let maximum = description["Max Capacity"] as? Int, maximum > 0
            else { continue }
            let minutes = description["Time to Empty"] as? Int ?? 0
            return BatteryStatus(
                level: min(1, Double(current) / Double(maximum)),
                isCharging: description["Is Charging"] as? Bool ?? false,
                isOnPowerAdapter: description["Power Source State"] as? String == "AC Power",
                minutesLeft: minutes > 0 ? minutes : nil
            )
        }
        return nil
    }

    static func memoryPressure() -> MemoryUsage.Pressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        switch level {
        case 4: return .critical
        case 2: return .warning
        default: return .normal
        }
    }
}
