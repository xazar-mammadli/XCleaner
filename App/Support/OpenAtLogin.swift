import AppKit
import ServiceManagement

/// Opening XCleaner when the user logs in, as one of macOS's login items (System Settings › General › Login Items).
@Observable
final class OpenAtLogin {
    private(set) var status = SMAppService.mainApp.status
    /// Why the last change didn't work, when it didn't.
    private(set) var failure: String?

    /// On, including while macOS waits for the user to allow it.
    var isOn: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }

    func set(_ isOn: Bool) {
        do {
            if isOn {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        refresh()
    }

    /// The user can also change it in System Settings at any time.
    func refresh() {
        status = SMAppService.mainApp.status
    }

    /// Whether macOS opened this copy as a login item. Only known while the launch's Apple event is being handled, as
    /// in `applicationDidFinishLaunching`.
    static var isLaunchingAtLogin: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == AEEventID(kAEOpenApplication)
            && event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }
}
