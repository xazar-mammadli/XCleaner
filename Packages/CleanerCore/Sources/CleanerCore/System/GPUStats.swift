import Foundation
import IOKit

public struct GPUStatus: Sendable, Equatable {
    public let name: String
    /// How busy the graphics processor is, from 0 to 1.
    public let utilization: Double
    /// Memory the graphics processor holds right now. On Apple silicon it shares the Mac's memory.
    public let memoryInUse: UInt64?
}

/// Graphics processor numbers from the I/O registry, which any user may read. The keys are the drivers' own,
/// the same Activity Monitor shows.
public enum GPUStats {
    /// The busiest graphics processor, or `nil` when the drivers report nothing.
    public static func status() -> GPUStatus? {
        var best: GPUStatus?
        forEachAccelerator { service in
            guard let stats = property(service, "PerformanceStatistics") as? [String: Any],
                  let percent = (stats["Device Utilization %"] as? NSNumber)?.doubleValue
            else { return }
            let status = GPUStatus(
                name: property(service, "model") as? String ?? "GPU",
                utilization: min(1, max(0, percent / 100)),
                memoryInUse: (stats["In use system memory"] as? NSNumber)?.uint64Value
            )
            if best.map({ status.utilization > $0.utilization }) ?? true { best = status }
        }
        return best
    }

    /// Graphics processor time each process used since it first drew something, in nanoseconds. Two readings give
    /// its share of the GPU in between.
    public static func timeByProcess() -> [Int32: UInt64] {
        var times: [Int32: UInt64] = [:]
        forEachAccelerator { service in
            var children: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &children) == KERN_SUCCESS else { return }
            defer { IOObjectRelease(children) }
            while case let client = IOIteratorNext(children), client != 0 {
                defer { IOObjectRelease(client) }
                // "pid 396, WindowServer"
                guard let creator = property(client, "IOUserClientCreator") as? String,
                      let usage = property(client, "AppUsage") as? [[String: Any]],
                      let pid = Int32(creator.split(separator: ",").first?.dropFirst(4) ?? "")
                else { continue }
                times[pid, default: 0] += usage.reduce(0) { $0 + (($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0) }
            }
        }
        return times
    }

    private static func forEachAccelerator(_ body: (io_object_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            body(service)
            IOObjectRelease(service)
        }
    }

    private static func property(_ entry: io_object_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
