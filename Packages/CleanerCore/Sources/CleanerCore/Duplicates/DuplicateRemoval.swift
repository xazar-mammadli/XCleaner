import Foundation

/// Decides which of the copies the user picked may go, right before they go.
public enum DuplicateRemoval {
    public enum SkipReason: Sendable, Equatable {
        /// No other copy of its content would be left.
        case lastCopy
        /// It is gone or was changed since the scan, so it may not be a copy anymore.
        case changed
    }

    public struct Skipped: Sendable {
        public let item: DuplicateItem
        public let reason: SkipReason
    }

    public struct Plan: Sendable {
        /// What to hand to `Cleaner`. A picked item inside a picked folder goes with its folder and isn't listed itself.
        public var items: [CleanableItem] = []
        public var skipped: [Skipped] = []
    }

    /// A copy goes only while another copy of its content stays: unchanged since the scan, not picked itself and not
    /// inside a folder that goes. A copy that changed since the scan stays too. Checking every group again after each
    /// change covers files and folders picked together, such as a folder and a file whose only other copy is inside it.
    public static func plan(removing picked: Set<URL>, in groups: [DuplicateGroup]) -> Plan {
        var plan = Plan()
        var checked: [URL: Bool] = [:]
        func isUnchanged(_ item: DuplicateItem) -> Bool {
            if let known = checked[item.url] { return known }
            let unchanged = item.isUnchanged()
            checked[item.url] = unchanged
            return unchanged
        }

        let all = groups.flatMap(\.items)
        var going = Set<URL>()
        for item in all where picked.contains(item.url) {
            if isUnchanged(item) {
                going.insert(item.url)
            } else {
                plan.skipped.append(Skipped(item: item, reason: .changed))
            }
        }

        var settled = false
        while !settled {
            settled = true
            let goingFolders = all.filter { $0.isFolder && going.contains($0.url) }.map { $0.url.path(percentEncoded: false) }
            for group in groups where group.items.contains(where: { going.contains($0.url) }) {
                let staying = group.items.contains { item in
                    !going.contains(item.url)
                        && !goingFolders.contains { DuplicateScanner.isInside(item.url.path(percentEncoded: false), $0) }
                        && isUnchanged(item)
                }
                guard !staying else { continue }
                for item in group.items where going.contains(item.url) {
                    going.remove(item.url)
                    plan.skipped.append(Skipped(item: item, reason: .lastCopy))
                }
                settled = false
            }
        }

        let goingFolders = all.filter { $0.isFolder && going.contains($0.url) }.map { $0.url.path(percentEncoded: false) }
        plan.items = all.filter { item in
            let path = item.url.path(percentEncoded: false)
            return going.contains(item.url) && !goingFolders.contains { $0 != path && DuplicateScanner.isInside(path, $0) }
        }
        .map(\.cleanableItem)
        return plan
    }
}
