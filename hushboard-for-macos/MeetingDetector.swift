import AppKit

/// Determines whether the user is currently in a meeting so the floating HUD
/// can be shown or hidden accordingly.
///
/// ## Detection strategy
///
/// Two parallel checks run each time `isMeetingAppRunning` is evaluated:
///
/// 1. **Native app check:** scans `NSWorkspace.shared.runningApplications` for
///    bundle IDs of known video-call apps. This is O(n) on running processes and
///    costs effectively nothing.
///
/// 2. **Browser check:** if any supported browser is running, walks its
///    Accessibility tree to inspect window titles and tab titles/URLs. Browsers
///    can host Google Meet, Zoom web, Teams web, Jitsi, etc. without a native app.
///    This path requires Accessibility permission and uses AX APIs, so it is only
///    reached when a browser is actually open.
///
/// ## Browser AX approach
///
/// Chrome exposes its tab bar as `AXTab` elements inside the window's AX tree.
/// Each `AXTab` has:
/// - `kAXTitleAttribute`: the page title shown in the tab strip
/// - `"AXURL"`: the current URL of that tab (Chrome-specific; not all browsers expose this)
///
/// We BFS the AX tree to depth 7 with a 300-element cap to avoid spending
/// significant CPU on browsers with many open tabs. Chrome's tab bar sits at
/// roughly depth 5 from the window element.
///
/// Firefox and Safari expose the *active* tab's title as the window title, so
/// checking `kAXTitleAttribute` on the window itself covers those browsers for
/// their foreground tab. Background tab scanning works for Chrome via `AXURL`.
class MeetingDetector {
    static let shared = MeetingDetector()
    private init() {}

    // MARK: - Known meeting app bundle IDs

    /// Native meeting/recording apps. Bundle IDs are stable across app updates.
    private let meetingBundleIDs: Set<String> = [
        "us.zoom.xos",                      // Zoom
        "com.microsoft.teams",              // Teams (classic)
        "com.microsoft.teams2",             // Teams (new)
        "com.apple.FaceTime",               // FaceTime
        "com.cisco.webex.meetings",         // Webex
        "com.cisco.webex.FranklinCentral",  // Webex (alternate bundle)
        "com.slack.slack",                  // Slack huddles / calls
        "com.hnc.Discord",                  // Discord voice/video
        "com.skype.skype",                  // Skype
        "com.loom.desktop",                 // Loom (screen + mic recording)
        "com.electron.bluejeans",           // BlueJeans
        "com.gotomeeting.GoToMeeting",      // GoToMeeting
        "com.ringcentral.meetings",         // RingCentral
        "com.whereby.app",                  // Whereby
        "com.chime.Amazon-Chime",           // Amazon Chime
        "com.timpler.screenstudio",         // Screen Studio (screen recorder with mic)
    ]

    // MARK: - Browsers that can host web-based meetings

    private let browserBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "org.mozilla.firefox",
        "com.apple.Safari",
        "company.thebrowser.Browser",   // Arc
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
    ]

    // MARK: - Meeting patterns

    /// Strings matched case-insensitively against browser window titles, AX tab
    /// titles, and tab URLs. Covers both URL fragments (for Chrome's `AXURL`)
    /// and the page-title strings that browsers show in the tab strip / window title.
    ///
    /// Order doesn't matter for correctness but URL fragments are listed first
    /// as a minor readability convention.
    private let meetingPatterns: [String] = [
        // ── URL fragments (matched against Chrome's AXURL on AXTab) ───────────
        "meet.google.com",      // Google Meet
        "zoom.us/j/",           // Zoom meeting join URL
        "zoom.us/wc/",          // Zoom web client
        "teams.microsoft.com",  // Teams web
        "whereby.com",          // Whereby
        "webex.com",            // Webex
        "bluejeans.com",        // BlueJeans
        "meet.jit.si",          // Jitsi

        // ── Page-title fragments (what browsers show as the window/tab title) ──
        // Chrome/Firefox/Safari expose the active tab's page title as the
        // window title, so these patterns catch foreground meeting tabs.
        "google meet",          // "Google Meet" or "Google Meet – Google Chrome"
        "meet - ",              // Google Meet room: "Meet - abc-defg-hij"
        "zoom meeting",         // Zoom web client page title
        "microsoft teams",      // Teams web / desktop page title
        "cisco webex",          // Webex page title
        "jitsi meet",           // Jitsi page title
        "whereby",              // Whereby page title
    ]

    // MARK: - Public API

    /// Returns `true` if at least one known video-call app is running, or a
    /// supported browser has a meeting tab active (foreground or background for
    /// Chrome, foreground-only for Firefox/Safari).
    var isMeetingAppRunning: Bool {
        // Fast path: native app check costs almost nothing.
        if NSWorkspace.shared.runningApplications.contains(where: {
            meetingBundleIDs.contains($0.bundleIdentifier ?? "")
        }) { return true }

        // Slower path: AX tree walk through each running browser.
        return isBrowserShowingMeeting()
    }

    /// The localized name of the first detected native meeting app, for display
    /// in status-bar tooltips or popover UI.
    var runningMeetingAppName: String? {
        NSWorkspace.shared.runningApplications.first {
            meetingBundleIDs.contains($0.bundleIdentifier ?? "")
        }?.localizedName
    }

    // MARK: - Browser detection via Accessibility

    private func isBrowserShowingMeeting() -> Bool {
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, browserBundleIDs.contains(id) else { continue }
            if browserWindowContainsMeeting(pid: app.processIdentifier) { return true }
        }
        return false
    }

    private func browserWindowContainsMeeting(pid: pid_t) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return false }

        for window in windows {
            // The window's AXTitle is the active tab's page title in Chrome,
            // Firefox, and Safari, covering the foreground tab for all browsers.
            if let title = axTitle(of: window), matchesMeetingPattern(title) { return true }

            // BFS walk to find individual AXTab elements (covers background tabs
            // in Chrome, which exposes AXURL on each tab even when not focused).
            if tabsContainMeeting(in: window) { return true }
        }
        return false
    }

    // MARK: - AX tab scanning

    /// Breadth-first traversal of the AX subtree rooted at `root`.
    ///
    /// - Parameters:
    ///   - maxDepth: Stops descending beyond this depth. Chrome's tab bar sits
    ///     at ~depth 5; 7 gives comfortable margin without excessive recursion.
    ///   - maxElements: Hard cap on total elements visited to bound CPU cost on
    ///     browsers with very deep or wide AX trees (e.g. many extensions loaded).
    private func tabsContainMeeting(in root: AXUIElement,
                                    maxDepth: Int = 7,
                                    maxElements: Int = 300) -> Bool {
        var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var checked = 0
        while !queue.isEmpty {
            let (element, depth) = queue.removeFirst()
            guard depth < maxDepth, checked < maxElements else { continue }
            checked += 1

            var roleRef: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
            let role = (roleRef as? String) ?? ""

            if role == "AXTab" {
                // Title check: works in Chrome, Firefox, and Safari for the
                // tab strip label (usually the page's <title> element).
                if let title = axTitle(of: element), matchesMeetingPattern(title) { return true }
                // URL check: Chrome exposes "AXURL" on AXTab as a CFURLRef or String.
                // This lets us detect background meeting tabs by URL even when
                // the tab isn't focused and its title hasn't been updated yet.
                if let url = axURL(of: element), matchesMeetingPattern(url) { return true }
            }

            var childrenRef: AnyObject?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                  let children = childrenRef as? [AXUIElement] else { continue }
            for child in children { queue.append((child, depth + 1)) }
        }
        return false
    }

    // MARK: - AX attribute helpers

    private func axTitle(of element: AXUIElement) -> String? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &ref) == .success,
              let title = ref as? String, !title.isEmpty else { return nil }
        return title
    }

    /// Reads Chrome's non-standard `"AXURL"` attribute from an `AXTab` element.
    /// The value can arrive as either a `CFURL` (bridged to `URL`) or a plain
    /// `CFString`, so we handle both.
    private func axURL(of element: AXUIElement) -> String? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(element, "AXURL" as CFString, &ref) == .success
        else { return nil }
        if let url = ref as? URL    { return url.absoluteString }
        if let str = ref as? String { return str }
        return nil
    }

    private func matchesMeetingPattern(_ text: String) -> Bool {
        let lower = text.lowercased()
        return meetingPatterns.contains(where: { lower.contains($0) })
    }
}
