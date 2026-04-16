import ServiceManagement

/// Registers and unregisters Hushboard as a login item using the modern
/// `SMAppService` API introduced in macOS 13.
///
/// ## Why SMAppService instead of LaunchAgents?
/// `SMAppService.mainApp` registers the app bundle directly with `launchd` without
/// requiring a separate `.plist` in `~/Library/LaunchAgents`. It's the only
/// Apple-sanctioned approach for non-sandboxed app-as-login-item since macOS 13,
/// and it shows up correctly in System Settings → General → Login Items.
///
/// ## Status checks before register/unregister
/// The `SMAppService` API throws if you call `register()` when the service is
/// already `.enabled`, or `unregister()` when it isn't. We guard against those
/// redundant calls to avoid silent errors logged to the console.
class LoginItemManager {
    static let shared = LoginItemManager()

    /// Called once at launch to re-apply a saved "launch at login" preference.
    /// Without this, the preference would only take effect after the user
    /// explicitly toggles the switch in the popover.
    func registerIfNeeded() {
        let enabled = UserDefaults.standard.bool(forKey: "launchAtLogin")
        if enabled { setEnabled(true) }
    }

    func setEnabled(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            print("LoginItemManager: SMAppService error — \(error.localizedDescription)")
        }
    }
}
