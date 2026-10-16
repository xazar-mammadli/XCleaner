import SwiftUI

/// The sections of the sidebar. Every section except the overview is still being built and lists the tools coming to it.
enum SidebarItem: String, CaseIterable, Identifiable {
    case overview, cleanup, applications, performance, files, privacy, utilities

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .overview: "Overview"
        case .cleanup: "Cleanup"
        case .applications: "Applications"
        case .performance: "Performance"
        case .files: "Files"
        case .privacy: "Privacy"
        case .utilities: "Utilities"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .cleanup: "sparkles"
        case .applications: "square.stack.3d.up"
        case .performance: "bolt"
        case .files: "folder"
        case .privacy: "hand.raised"
        case .utilities: "wrench.and.screwdriver"
        }
    }

    var summary: LocalizedStringResource {
        switch self {
        case .overview: "Your Mac at a glance."
        case .cleanup: "Remove junk your Mac doesn't need: caches, logs, leftovers and old installers."
        case .applications: "Uninstall apps completely, find what deleted apps left behind and keep apps up to date."
        case .performance: "See what starts with your Mac and what slows it down."
        case .files: "Find out what takes up space: big files, duplicates and a map of your disk."
        case .privacy: "Clear browsing traces and check which apps can reach your data."
        case .utilities: "Handy extras: a menu bar monitor, hidden files and your cleanup history."
        }
    }

    var plannedTools: [PlannedTool] {
        switch self {
        case .overview:
            []
        case .cleanup:
            [
                PlannedTool(id: "system-junk", title: "System Junk", phase: 1, systemImage: "sparkles",
                            detail: "User caches, logs and developer junk such as Xcode build data."),
                PlannedTool(id: "installers", title: "Installers & Downloads", phase: 1, systemImage: "shippingbox",
                            detail: "Old .dmg and .pkg installers, unneeded archives and old screenshots."),
                PlannedTool(id: "trash-bins", title: "Trash Bins", phase: 1, systemImage: "trash",
                            detail: "The Trash on your Mac and on connected drives."),
                PlannedTool(id: "mail-attachments", title: "Mail Attachments", phase: 3, systemImage: "paperclip",
                            detail: "Copies of attachments saved by the Mail app."),
                PlannedTool(id: "system-level-junk", title: "System-Level Junk", phase: 3, systemImage: "gearshape.2",
                            detail: "Caches and logs in system folders, removed through a secure helper."),
            ]
        case .applications:
            [
                PlannedTool(id: "uninstaller", title: "Uninstaller", phase: 2, systemImage: "xmark.bin",
                            detail: "Remove an app together with all of its support files."),
                PlannedTool(id: "remaining-files", title: "Remaining Files", phase: 2, systemImage: "questionmark.folder",
                            detail: "Files left behind by apps that were already deleted."),
                PlannedTool(id: "reset-apps", title: "Reset Apps", phase: 2, systemImage: "arrow.counterclockwise",
                            detail: "Return an app to its first-launch state without reinstalling it."),
                PlannedTool(id: "extensions", title: "Extensions", phase: 3, systemImage: "puzzlepiece.extension",
                            detail: "Preference panes, plug-ins and browser extensions."),
                PlannedTool(id: "updater", title: "Updater", phase: 4, systemImage: "arrow.down.circle",
                            detail: "Updates from developers, the App Store and Homebrew in one list."),
            ]
        case .performance:
            [
                PlannedTool(id: "startup-items", title: "Startup Items", phase: 3, systemImage: "power",
                            detail: "Login items, launch agents and background services."),
                PlannedTool(id: "heavy-apps", title: "Heavy Apps", phase: 3, systemImage: "speedometer",
                            detail: "Apps that use the most memory and processor time."),
                PlannedTool(id: "maintenance", title: "Maintenance", phase: 3, systemImage: "wrench.adjustable",
                            detail: "Reindex Spotlight and Mail, flush the DNS cache and thin local snapshots."),
            ]
        case .files:
            [
                PlannedTool(id: "large-files", title: "Biggest & Old Files", phase: 1, systemImage: "doc.text.magnifyingglass",
                            detail: "Large files you haven't opened in a long time, filtered by type."),
                PlannedTool(id: "disk-map", title: "Disk Map", phase: 2, systemImage: "chart.pie",
                            detail: "An interactive map of what fills your disk."),
                PlannedTool(id: "duplicates", title: "Duplicates", phase: 4, systemImage: "doc.on.doc",
                            detail: "Identical files and folders, with Smart Select and folder merging."),
                PlannedTool(id: "similar-photos", title: "Similar Photos", phase: 4, systemImage: "photo.on.rectangle",
                            detail: "Near-identical shots, so you can keep the best one."),
            ]
        case .privacy:
            [
                PlannedTool(id: "browser-data", title: "Browser Data", phase: 3, systemImage: "globe",
                            detail: "History, cookies and caches of Safari, Chrome, Firefox, Edge and Brave."),
                PlannedTool(id: "app-permissions", title: "App Permissions", phase: 4, systemImage: "hand.raised",
                            detail: "Which apps can use your camera, microphone, screen and files."),
                PlannedTool(id: "background-check", title: "Background Item Check", phase: 4, systemImage: "checkmark.shield",
                            detail: "Flags unsigned or suspicious items that start automatically."),
            ]
        case .utilities:
            [
                PlannedTool(id: "history", title: "Cleanup History", phase: 1, systemImage: "clock.arrow.circlepath",
                            detail: "Everything XCleaner removed, and when."),
                PlannedTool(id: "menu-bar", title: "Menu Bar Monitor", phase: 3, systemImage: "menubar.rectangle",
                            detail: "Processor, memory, disk, battery and network at a glance."),
                PlannedTool(id: "hidden-files", title: "Hidden Files", phase: 4, systemImage: "eye.slash",
                            detail: "Show, find and manage hidden files."),
            ]
        }
    }
}

struct PlannedTool: Identifiable {
    let id: String
    let title: LocalizedStringResource
    let phase: Int
    let systemImage: String
    let detail: LocalizedStringResource
}
