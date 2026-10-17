import AppKit
import CleanerCore
import SwiftUI

/// Where XCleaner's releases are published.
enum ReleaseSource {
    static let latest = URL(string: "https://api.github.com/repos/xazar-mammadli/XCleaner/releases/latest")!
    static let page = URL(string: "https://github.com/xazar-mammadli/XCleaner/releases")!
    /// The project page, which lists the tools and how XCleaner keeps files safe.
    static let help = URL(string: "https://github.com/xazar-mammadli/XCleaner#readme")!
}

/// Finds newer releases of XCleaner and installs them. A check asks GitHub for the latest release and sends nothing
/// about this Mac. An update replaces XCleaner only after its signature shows it comes from the same developer.
@Observable
final class UpdateModel {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(ReleaseInfo)
        case downloading(Double)
        case installing
        case failed(String)
    }

    private(set) var state = State.idle
    var isShowingSheet = false
    private var task: Task<Void, Never>?

    static let checkInterval: TimeInterval = 24 * 60 * 60

    var currentVersion: AppVersion {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init)
            ?? AppVersion("0")!
    }

    var lastChecked: Date? { UserDefaults.standard.object(forKey: PreferenceKey.lastUpdateCheck) as? Date }

    /// Whether this copy can put an update in place itself: it is signed like a release, and sits where it can be replaced.
    var canInstallItself: Bool {
        UpdateInstaller.requirementOfRunningApp() != nil && UpdateInstaller.canReplace(Bundle.main.bundleURL)
    }

    /// At launch: checks once a day while the user allows it, and only speaks up when there is something new.
    func checkIfDue() {
        guard Preferences.checksForUpdates, (lastChecked.map { Date.now.timeIntervalSince($0) > Self.checkInterval } ?? true) else { return }
        check(userInitiated: false)
    }

    func check(userInitiated: Bool) {
        guard task == nil else {
            if userInitiated { isShowingSheet = true }
            return
        }
        state = .checking
        if userInitiated { isShowingSheet = true }
        task = Task {
            defer { task = nil }
            do {
                var request = URLRequest(url: ReleaseSource.latest)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                UserDefaults.standard.set(Date.now, forKey: PreferenceKey.lastUpdateCheck)
                guard (response as? HTTPURLResponse)?.statusCode == 200, let release = ReleaseInfo.parse(data) else {
                    // No release published yet counts as up to date.
                    state = (response as? HTTPURLResponse)?.statusCode == 404 ? .upToDate : .failed(String(localized: "GitHub gave an answer XCleaner couldn't read."))
                    return
                }
                if release.version > currentVersion {
                    state = .available(release)
                    let skipped = UserDefaults.standard.string(forKey: PreferenceKey.skippedVersion).flatMap(AppVersion.init)
                    if userInitiated || skipped != release.version { isShowingSheet = true }
                } else {
                    state = .upToDate
                }
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func skip(_ release: ReleaseInfo) {
        UserDefaults.standard.set(release.version.description, forKey: PreferenceKey.skippedVersion)
        isShowingSheet = false
    }

    func openReleasePage(_ release: ReleaseInfo? = nil) {
        NSWorkspace.shared.open(release?.pageURL ?? ReleaseSource.page)
    }

    /// Downloads the release's disk image, checks the app inside, puts it in place of this one and starts it.
    func install(_ release: ReleaseInfo) {
        guard let imageURL = release.imageURL, task == nil else { return }
        let installed = Bundle.main.bundleURL
        let identifier = Bundle.main.bundleIdentifier ?? "com.xazar.xcleaner"
        let current = currentVersion
        state = .downloading(0)
        task = Task {
            defer { task = nil }
            let folder = FileManager.default.temporaryDirectory.appending(path: "XCleaner-update-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: folder) }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let image = try await download(imageURL, to: folder.appending(path: "XCleaner.dmg"))
                state = .installing
                try await Task.detached(priority: .userInitiated) {
                    guard let requirement = UpdateInstaller.requirementOfRunningApp() else { throw UpdateInstaller.Failure.notFromRelease }
                    guard UpdateInstaller.canReplace(installed) else { throw UpdateInstaller.Failure.notReplaceable }
                    let candidate = try UpdateInstaller.extractApp(fromImage: image, named: "XCleaner.app", into: folder)
                    if let failure = UpdateInstaller.verify(candidate, bundleIdentifier: identifier, newerThan: current, requirement: requirement) {
                        throw failure
                    }
                    try UpdateInstaller.replace(installed, with: candidate, trash: SystemTrash())
                }.value
                AppRelauncher.relaunch { [weak self] in
                    self?.state = .failed(String(localized: "XCleaner was updated, but the new version didn't open. Quit XCleaner and open it again."))
                }
            } catch let failure as UpdateInstaller.Failure {
                state = .failed(failure.message)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Downloads to `destination`, reporting progress as it goes.
    private func download(_ url: URL, to destination: URL) async throws -> URL {
        let progress = Progress(totalUnitCount: 100)
        let watcher = Task { [weak self] in
            while !Task.isCancelled {
                self?.state = .downloading(progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { watcher.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: url) { location, response, error in
                guard let location, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    continuation.resume(throwing: error ?? UpdateInstaller.Failure.downloadFailed)
                    return
                }
                do {
                    try FileManager.default.moveItem(at: location, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            progress.addChild(task.progress, withPendingUnitCount: 100)
            task.resume()
        }
    }
}

extension UpdateInstaller.Failure {
    var message: String {
        switch self {
        case .notFromRelease: String(localized: "This copy of XCleaner wasn't installed from a release, so it can't update itself. Download the new version from the release page.")
        case .notReplaceable: String(localized: "XCleaner can't replace itself where it is. Move it to the Applications folder, or download the new version from the release page.")
        case .downloadFailed: String(localized: "The download failed. Check the internet connection and try again.")
        case .noAppInImage: String(localized: "The downloaded disk image holds no XCleaner.")
        case .wrongApp: String(localized: "The downloaded app isn't a newer XCleaner, so it was left alone.")
        case .signatureMismatch: String(localized: "The downloaded app isn't signed by XCleaner's developer, so it was left alone.")
        case .installFailed(let reason): String(localized: "The update couldn't be put in place: \(reason)")
        }
    }
}
