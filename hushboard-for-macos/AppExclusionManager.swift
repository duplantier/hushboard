import AppKit
import Foundation

/// Manages a user-defined list of apps where Hushboard should *not* mute the mic.
///
/// Excluded apps are persisted as an array of bundle ID strings in `UserDefaults`.
/// `HushboardViewModel` is expected to call `isExcluded(_:)` before muting to
/// respect apps the user has whitelisted (e.g. a DAW or voice-memo app where
/// keyboard input should never trigger a mute).
///
/// Note: The exclusion UI is not yet surfaced in the popover; this class is
/// infrastructure ready for a future "Excluded Apps" settings panel.
class AppExclusionManager {
    static let shared = AppExclusionManager()
    private init() {}

    private let defaultsKey = "excludedAppBundleIDs"

    /// The current set of excluded bundle IDs. Persisted automatically on every write.
    var excludedIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: defaultsKey) }
    }

    /// The application that currently has key focus.
    var frontmostApp: NSRunningApplication? {
        NSWorkspace.shared.frontmostApplication
    }

    var frontmostAppName: String {
        frontmostApp?.localizedName ?? "—"
    }

    /// True if the frontmost app's bundle ID appears in the exclusion list.
    var isFrontmostExcluded: Bool {
        guard let id = frontmostApp?.bundleIdentifier else { return false }
        return excludedIDs.contains(id)
    }

    /// Adds the frontmost app to the exclusion list if absent; removes it if present.
    func toggleFrontmostApp() {
        guard let id = frontmostApp?.bundleIdentifier else { return }
        var ids = excludedIDs
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        excludedIDs = ids
    }

    func isExcluded(_ bundleID: String) -> Bool {
        excludedIDs.contains(bundleID)
    }
}
