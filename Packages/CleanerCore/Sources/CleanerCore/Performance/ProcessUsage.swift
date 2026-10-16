import Darwin
import Foundation

/// One process, measured at one moment.
public struct ProcessSample: Sendable, Hashable {
    public let pid: Int32
    /// The executable's path.
    public let path: String
    /// Processor time used since the process started, in nanoseconds.
    public let cpuTime: UInt64
    /// Memory the process is responsible for: what Activity Monitor shows in its Memory column.
    public let footprint: UInt64

    public init(pid: Int32, path: String, cpuTime: UInt64, footprint: UInt64) {
        self.pid = pid
        self.path = path
        self.cpuTime = cpuTime
        self.footprint = footprint
    }

    /// The outermost app bundle the executable sits in, so an app's helper processes count toward the app.
    public var appBundlePath: String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }
}

/// Reads processor time and memory of every process the user may inspect, which is every process of their own.
public enum ProcessSampler {
    public static func sample() -> [ProcessSample] {
        let expected = proc_listallpids(nil, 0)
        guard expected > 0 else { return [] }
        // Room for processes started between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(expected) + 64)
        let found = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard found > 0 else { return [] }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return pids.prefix(Int(found)).compactMap { pid in
            guard pid > 0, let path = executablePath(of: pid) else { return nil }
            var usage = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            // Processes of other users, root included, can't be read without privileges and are left out.
            guard result == 0 else { return nil }
            // Times come in Mach ticks, which are not nanoseconds on Apple silicon.
            let ticks = usage.ri_user_time + usage.ri_system_time
            let nanoseconds = ticks * UInt64(timebase.numer) / UInt64(max(timebase.denom, 1))
            return ProcessSample(pid: pid, path: path, cpuTime: nanoseconds, footprint: usage.ri_phys_footprint)
        }
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }
}

/// What one app uses with all of its helper processes, or one process that belongs to no app.
public struct ProcessGroup: Sendable, Identifiable, Hashable {
    /// The app bundle's path, or the executable's path for a process outside any app.
    public let id: String
    public let name: String
    /// Set for apps; `nil` for a process outside any app.
    public let bundlePath: String?
    /// Whether it ships with macOS.
    public let isSystem: Bool
    public let pids: [Int32]
    /// Processor use since the previous sample. 100 means one core kept busy, so it can go past 100.
    public let cpuPercent: Double
    /// Share of the graphics processor's time since the previous sample, from 0 to 100.
    public let gpuPercent: Double
    public let footprint: UInt64

    public init(
        id: String, name: String, bundlePath: String?, isSystem: Bool, pids: [Int32], cpuPercent: Double, gpuPercent: Double = 0,
        footprint: UInt64
    ) {
        self.id = id
        self.name = name
        self.bundlePath = bundlePath
        self.isSystem = isSystem
        self.pids = pids
        self.cpuPercent = cpuPercent
        self.gpuPercent = gpuPercent
        self.footprint = footprint
    }
}

public enum ProcessUsage {
    /// Groups `current` by app and works out processor use since `previous`, measured `elapsed` nanoseconds earlier,
    /// and graphics use from GPU times read at the same two moments (see `GPUStats.timeByProcess()`).
    /// A process missing from `previous` started in between; its time is unknown and counts as zero until next time.
    public static func groups(
        current: [ProcessSample], previous: [ProcessSample], elapsed: UInt64,
        gpuTimes: [Int32: UInt64] = [:], previousGPUTimes: [Int32: UInt64] = [:]
    ) -> [ProcessGroup] {
        let before = Dictionary(previous.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var members: [String: [ProcessSample]] = [:]
        for sample in current {
            members[sample.appBundlePath ?? sample.path, default: []].append(sample)
        }
        return members.map { key, samples in
            let busy = samples.reduce(UInt64(0)) { total, sample in
                guard let earlier = before[sample.pid], earlier.path == sample.path, sample.cpuTime >= earlier.cpuTime
                else { return total }
                return total + (sample.cpuTime - earlier.cpuTime)
            }
            let graphics = samples.reduce(UInt64(0)) { total, sample in
                guard let now = gpuTimes[sample.pid], let earlier = previousGPUTimes[sample.pid], now >= earlier else { return total }
                return total + (now - earlier)
            }
            let bundlePath = samples[0].appBundlePath
            return ProcessGroup(
                id: key,
                name: displayName(of: key, isApp: bundlePath != nil),
                bundlePath: bundlePath,
                isSystem: isSystemPath(key),
                pids: samples.map(\.pid).sorted(),
                cpuPercent: elapsed > 0 ? Double(busy) / Double(elapsed) * 100 : 0,
                gpuPercent: elapsed > 0 ? min(100, Double(graphics) / Double(elapsed) * 100) : 0,
                footprint: samples.reduce(0) { $0 + $1.footprint }
            )
        }
    }

    static func displayName(of path: String, isApp: Bool) -> String {
        guard isApp else { return (path as NSString).lastPathComponent }
        let name = FileManager.default.displayName(atPath: path)
        return name.lowercased().hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    static func isSystemPath(_ path: String) -> Bool {
        // `/usr/local` holds what the user installed, Homebrew on Intel Macs among it.
        guard !path.hasPrefix("/usr/local/") else { return false }
        return ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/"].contains { path.hasPrefix($0) }
    }
}
