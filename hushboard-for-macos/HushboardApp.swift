import SwiftUI
import AppKit

// MARK: - App entry point

/// App entry point. Using `@NSApplicationDelegateAdaptor` instead of a pure SwiftUI
/// lifecycle gives us `applicationWillTerminate`, essential for unmuting the mic
/// before the process exits so the user's mic isn't left silenced after a crash.
@main
struct HushboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    /// No visible scenes. Hushboard lives entirely in the menu bar and the
    /// floating HUD panel. The `Settings` scene is a no-op placeholder required
    /// by SwiftUI's App protocol when using `@NSApplicationDelegateAdaptor`.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

// MARK: - App delegate

class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `.accessory` hides the app from the Dock and Cmd-Tab switcher.
        // Must be set before any UI is shown, otherwise the Dock icon flickers.
        NSApp.setActivationPolicy(.accessory)

        StatusBarController.shared.setup()

        // The floating HUD shows during meetings even when the menu bar is
        // hidden (fullscreen) or crowded out by other status-bar icons.
        FloatingHUDController.shared.setup()

        LoginItemManager.shared.registerIfNeeded()

        if UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            // Returning user: request Accessibility permission (if not yet granted)
            // and start the keyboard monitor immediately.
            requestAccessibilityPermissionIfNeeded()
        } else {
            // First launch: walk the user through the onboarding steps before
            // starting the monitor so we don't silently fail on missing permission.
            OnboardingWindowController.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Teardown order matters: stop the keyboard monitor first so no new
        // mute calls can race with the unmute in `teardown()`, then close the HUD.
        HushboardViewModel.shared.teardown()
        FloatingHUDController.shared.teardown()
    }

    // MARK: - Private

    private func requestAccessibilityPermissionIfNeeded() {
        // Passing `kAXTrustedCheckOptionPrompt = true` triggers the system
        // permission dialog if the app doesn't already have Accessibility access.
        // The call is intentionally fire-and-forget; the ViewModel polls for the
        // grant independently via `startPermissionPolling()`.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        HushboardViewModel.shared.startMonitoring()
    }
}
