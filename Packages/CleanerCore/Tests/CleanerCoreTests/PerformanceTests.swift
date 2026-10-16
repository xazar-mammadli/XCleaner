import Foundation
import Testing
@testable import CleanerCore

@Suite("ProcessUsage")
struct ProcessUsageTests {
    @Test func samplesThisProcess() throws {
        let sample = try #require(ProcessSampler.sample().first { $0.pid == getpid() })
        #expect(sample.footprint > 0)
        #expect(sample.path.hasPrefix("/"))
    }

    @Test func groupsHelpersUnderTheirApp() throws {
        let app = "/Applications/Browser.app"
        let main = "\(app)/Contents/MacOS/Browser"
        let helper = "\(app)/Contents/Frameworks/Browser Helper.app/Contents/MacOS/Browser Helper"
        let previous = [
            ProcessSample(pid: 10, path: main, cpuTime: 1_000, footprint: 100),
            ProcessSample(pid: 11, path: helper, cpuTime: 0, footprint: 50),
        ]
        let current = [
            ProcessSample(pid: 10, path: main, cpuTime: 501_000, footprint: 120),
            ProcessSample(pid: 11, path: helper, cpuTime: 250_000, footprint: 60),
            // Started since the last sample, so its time is not known yet.
            ProcessSample(pid: 12, path: helper, cpuTime: 9_000_000, footprint: 30),
            ProcessSample(pid: 20, path: "/usr/local/bin/tool", cpuTime: 4_000, footprint: 10),
            ProcessSample(pid: 30, path: "/usr/libexec/daemon", cpuTime: 0, footprint: 5),
        ]
        let groups = ProcessUsage.groups(
            current: current, previous: previous, elapsed: 1_000_000,
            gpuTimes: [10: 300_000, 11: 50_000, 20: 9_000], previousGPUTimes: [10: 100_000, 11: 50_000]
        )

        let browser = try #require(groups.first { $0.id == app })
        #expect(browser.name == "Browser")
        #expect(browser.bundlePath == app)
        #expect(browser.pids == [10, 11, 12])
        #expect(browser.footprint == 210)
        #expect(abs(browser.cpuPercent - 75) < 0.001)
        #expect(abs(browser.gpuPercent - 20) < 0.001)
        #expect(!browser.isSystem)

        let tool = try #require(groups.first { $0.id == "/usr/local/bin/tool" })
        #expect(tool.name == "tool")
        #expect(tool.bundlePath == nil)
        #expect(tool.cpuPercent == 0)
        // No earlier GPU reading for it, so no share yet.
        #expect(tool.gpuPercent == 0)
        #expect(!tool.isSystem)

        #expect(groups.first { $0.id == "/usr/libexec/daemon" }?.isSystem == true)
    }
}

@Suite("SystemStats")
struct SystemStatsTests {
    @Test func readsMemory() throws {
        let memory = try #require(SystemStats.memory())
        #expect(memory.totalBytes == ProcessInfo.processInfo.physicalMemory)
        #expect(memory.usedBytes > 0)
        #expect(memory.usedBytes <= memory.totalBytes)
    }

    @Test func networkTrafficSurvivesCounterWrap() {
        let before = NetworkCounters(interfaces: ["en0": .init(received: UInt32.max - 9, sent: 100), "en1": .init(received: 5, sent: 5)])
        let after = NetworkCounters(interfaces: ["en0": .init(received: 20, sent: 150), "en5": .init(received: 999, sent: 999)])
        let traffic = after.bytes(since: before)
        // en0 wrapped past zero; en1 went away and en5 is new, so neither counts.
        #expect(traffic.received == 30)
        #expect(traffic.sent == 50)
    }

    @Test func readsTheGraphicsProcessor() {
        // Every Mac XCleaner runs on has a GPU, though a virtual machine might not report one.
        if let gpu = GPUStats.status() {
            #expect(gpu.utilization >= 0 && gpu.utilization <= 1)
            #expect(!gpu.name.isEmpty)
        }
        _ = GPUStats.timeByProcess()
    }

    @Test func readsBatteryOrNothing() {
        if let battery = SystemStats.battery() {
            #expect(battery.level >= 0 && battery.level <= 1)
        }
        _ = SystemStats.networkCounters()
    }

    @Test func processorLoadStaysBetweenZeroAndOne() throws {
        let first = try #require(SystemStats.processorTicks())
        let second = try #require(SystemStats.processorTicks())
        let load = second.load(since: first)
        #expect(load >= 0 && load <= 1)
    }
}

extension Sandbox {
    @discardableResult
    func plist(_ relative: String, _ contents: [String: Any]) throws -> URL {
        let url = url(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: contents, format: .xml, options: 0).write(to: url)
        return url
    }
}

@Suite("StartupItems")
struct StartupItemTests {
    @Test func readsUserAgentsAndSpotsProblems() throws {
        let sandbox = try Sandbox()
        let tool = try sandbox.file("bin/tool").path(percentEncoded: false)
        try sandbox.plist("Library/LaunchAgents/com.example.ok.plist", [
            "Label": "com.example.ok", "ProgramArguments": [tool, "--quiet"], "RunAtLoad": true,
            "AssociatedBundleIdentifiers": ["com.example.app"],
        ])
        try sandbox.plist("Library/LaunchAgents/com.example.gone.plist", [
            "Label": "com.example.gone", "Program": sandbox.url("bin/missing").path(percentEncoded: false), "KeepAlive": true,
        ])
        try sandbox.plist("Library/LaunchAgents/com.example.empty.plist", [:])
        try sandbox.plist("Library/LaunchAgents/com.example.timer.plist", [
            "Label": "com.example.timer", "Program": tool, "StartInterval": 3600, "Disabled": true,
        ])

        let items = LaunchItemScanner(home: sandbox.root).folderItems().filter(\.isUsers)
        let byLabel = Dictionary(uniqueKeysWithValues: items.map { ($0.label, $0) })
        #expect(byLabel.count == 4)

        let fine = try #require(byLabel["com.example.ok"])
        #expect(fine.problem == nil)
        #expect(fine.kind == .agent)
        #expect(fine.schedule == .atLaunch)
        #expect(fine.program == tool)
        #expect(fine.bundleIdentifiers == ["com.example.app"])

        #expect(byLabel["com.example.gone"]?.problem == .programMissing)
        #expect(byLabel["com.example.gone"]?.schedule == .alwaysRunning)
        #expect(byLabel["com.example.empty"]?.problem == .empty)
        #expect(byLabel["com.example.timer"]?.schedule == .periodically)
        #expect(byLabel["com.example.timer"]?.isDisabledInFile == true)
    }

    @Test func findsJobsAndLoginItemsInsideApps() throws {
        let sandbox = try Sandbox()
        try sandbox.app("Applications/Sync.app", id: "com.example.sync")
        try sandbox.app("Applications/Sync.app/Contents/Library/LoginItems/Sync Helper.app", id: "com.example.sync.helper")
        try sandbox.file("Applications/Sync.app/Contents/MacOS/agent")
        try sandbox.plist("Applications/Sync.app/Contents/Library/LaunchAgents/com.example.sync.agent.plist", [
            "Label": "com.example.sync.agent", "BundleProgram": "Contents/MacOS/agent", "RunAtLoad": true,
        ])
        let apps = AppInventory(folders: [sandbox.url("Applications")]).apps()
        let sync = try #require(apps.first { $0.bundleIdentifier == "com.example.sync" })

        let jobs = LaunchItemScanner(home: sandbox.root).bundledItems(in: [sync])
        #expect(jobs.map(\.label) == ["com.example.sync.agent"])
        #expect(jobs.first?.problem == nil)
        #expect(jobs.first?.bundledIn == sync.url)

        let logins = LoginItem.items(in: [sync])
        #expect(logins.map(\.bundleIdentifier) == ["com.example.sync.helper"])
        #expect(logins.first?.name == "Sync Helper")
    }

    @Test func readsLaunchctlOutput() {
        let overrides = LaunchControl.parseOverrides("""
            disabled services = {
                "com.example.on" => enabled
                "com.example.off" => disabled
                "com.example.old" => true
            }
            """)
        #expect(overrides == ["com.example.on": false, "com.example.off": true, "com.example.old": true])

        let services = LaunchControl.parseServices("""
            gui/501 = {
                type = User
                services = {
                       1234      - \tcom.example.running
                          0      0 \tcom.example.idle
                }
                disabled services = {
                    "com.example.off" => disabled
                }
            }
            """)
        #expect(services == ["com.example.running": 1234, "com.example.idle": 0])
    }
}

@Suite("StartupSnapshot")
struct StartupSnapshotTests {
    func job(_ label: String, kind: LaunchItem.Kind = .agent, problem: LaunchItem.Problem? = nil, disabledInFile: Bool = false) -> LaunchItem {
        LaunchItem(
            label: label, plistURL: URL(filePath: "/tmp/\(label).plist"), kind: kind, isUsers: false, bundledIn: nil,
            program: "/bin/true", bundleIdentifiers: [], schedule: .atLaunch, problem: problem, isDisabledInFile: disabledInFile
        )
    }

    @Test func overridesWinOverTheFile() {
        let snapshot = StartupSnapshot(
            loginItems: [], jobs: [],
            userOverrides: ["a.off": true, "b.on": false], systemOverrides: ["d.off": true],
            userJobs: ["b.on": 42, "c.idle": 0], systemJobs: ["d.off": 7]
        )
        #expect(!snapshot.isOn(job("a.off")))
        #expect(snapshot.isOn(job("b.on", disabledInFile: true)))
        #expect(!snapshot.isOn(job("c.idle", disabledInFile: true)))
        #expect(snapshot.isOn(job("c.free")))
        #expect(!snapshot.isOn(job("d.off", kind: .daemon)))
        #expect(!snapshot.isOn(job("e.broken", problem: .programMissing)))

        #expect(snapshot.isRunning(job("b.on")))
        #expect(!snapshot.isRunning(job("c.idle")))
        // The same label in the other domain says nothing about this one.
        #expect(!snapshot.isRunning(job("d.off")))
        #expect(snapshot.isRunning(job("d.off", kind: .daemon)))
    }
}
