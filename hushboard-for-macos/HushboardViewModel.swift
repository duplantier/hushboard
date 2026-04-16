import SwiftUI
import Combine

// MARK: - State

/// The four mutually-exclusive operating states of Hushboard.
/// Views and the status-bar icon are driven entirely by this enum; no
/// separate boolean flags for "is muted" or "has permission" are needed.
enum HushboardState {
    /// User has paused Hushboard. Keyboard events are ignored; mic is not touched.
    case disabled
    /// Accessibility permission hasn't been granted yet. The keyboard monitor
    /// cannot start without it, so we enter a polling loop waiting for the grant.
    case waitingPermission
    /// Monitoring is active. No typing detected; mic is in its natural state.
    case idle
    /// Typing was detected. We issued the mute call and are waiting for the
    /// debounce timer to expire before unmuting.
    case muted
}

// MARK: - View model

/// Central state machine and coordinator for Hushboard.
///
/// Responsibilities:
/// - Owns the `HushboardState` published to all views
/// - Drives `MicController` (mute / unmute) in response to keyboard events
/// - Manages the debounce timer that delays unmute after the last keystroke
/// - Persists user preferences via `@AppStorage`
/// - Tracks mute-count statistics (session + daily)
class HushboardViewModel: ObservableObject {

    static let shared = HushboardViewModel()

    // MARK: - Published state

    @Published var state: HushboardState = .waitingPermission
    @Published var isEnabled: Bool = true
    @Published var lastMutedAt: Date? = nil

    /// Mutes issued during the current process lifetime (resets on relaunch).
    @Published var muteCount: Int = 0
    /// Mutes issued today, persisted across launches via `UserDefaults`.
    @Published var todayMuteCount: Int = 0

    // MARK: - Persisted preferences

    /// How long (in seconds) to wait after the last keystroke before unmuting.
    /// Longer values prevent rapid mute/unmute cycling when the user pauses briefly.
    @AppStorage("debounceSeconds") var debounceSeconds: Double = 1.0
    @AppStorage("launchAtLogin")   var launchAtLogin: Bool = true
    @AppStorage("isEnabled")       var isEnabledStored: Bool = true

    // MARK: - Private

    private var debounceTimer: Timer?
    private var permissionPollTimer: Timer?

    /// Tracks whether *we* issued the most recent mute call. This prevents
    /// Hushboard from unmuting a mic that was already muted externally (e.g. the
    /// user muted manually in Zoom before typing). Without this flag, releasing
    /// the debounce timer would incorrectly unmute a mic the user intentionally left muted.
    private var didWeMute: Bool = false

    private init() {
        isEnabled = isEnabledStored
        loadTodayStats()
    }

    // MARK: - Startup / permission flow

    /// Entry point called from `AppDelegate` after Accessibility permission has
    /// been requested. If permission is already granted, the keyboard monitor
    /// starts immediately; otherwise we enter a 2-second polling loop.
    func startMonitoring() {
        guard AXIsProcessTrusted() else {
            state = .waitingPermission
            startPermissionPolling()
            return
        }
        beginKeyboardMonitor()
    }

    /// Polls every 2 seconds until `AXIsProcessTrusted()` returns true.
    /// We use polling (rather than a notification) because macOS doesn't post a
    /// reliable notification when TCC access is granted to a running process.
    private func startPermissionPolling() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) {
            [weak self] _ in
            if AXIsProcessTrusted() {
                self?.permissionPollTimer?.invalidate()
                self?.beginKeyboardMonitor()
            }
        }
    }

    // MARK: - Keyboard monitor lifecycle

    private func beginKeyboardMonitor() {
        // Clear any stale hardware mute flag from a previous crash. Without this,
        // a crashed session can leave the mic permanently muted on relaunch.
        MicController.shared.recoverIfNeeded()

        KeyboardMonitor.shared.onKeyActivity = { [weak self] in
            self?.handleKeyActivity()
        }
        KeyboardMonitor.shared.onHotkeyTriggered = { [weak self] in
            self?.toggleEnabled()
        }
        KeyboardMonitor.shared.start()

        // Re-evaluate state when the default input device changes (e.g. USB mic
        // plugged in or Bluetooth headset connected mid-meeting).
        MicController.shared.startListeningForDeviceChanges { [weak self] in
            self?.handleDeviceChange()
        }

        state = isEnabled ? .idle : .disabled
    }

    // MARK: - Core mute / unmute logic

    /// Called on every `keyDown` event from `KeyboardMonitor`.
    /// Dispatches to the main queue because CoreGraphics delivers events on a
    /// background thread, while all state mutations must happen on main.
    func handleKeyActivity() {
        guard isEnabled else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.muteIfNeeded()
            self.resetDebounceTimer()
        }
    }

    /// Mutes the mic and transitions to `.muted` if not already there.
    /// The guard on `state != .muted` prevents redundant CoreAudio calls on
    /// every keystroke while the debounce window is still open.
    private func muteIfNeeded() {
        guard state != .muted else { return }

        // Only set `didWeMute` when the mic was actually unmuted before we
        // intervened. If the user already muted externally, we don't own the state.
        if !MicController.shared.isMuted {
            MicController.shared.mute()
            didWeMute = true
        } else {
            didWeMute = false
        }

        state = .muted
        lastMutedAt = Date()
        muteCount += 1
        incrementTodayStats()
        StatusBarController.shared.updateIcon()
    }

    /// Restarts the debounce countdown. Each new keystroke resets the clock so
    /// the mic stays muted as long as the user is actively typing.
    private func resetDebounceTimer() {
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(
            withTimeInterval: debounceSeconds,
            repeats: false
        ) { [weak self] _ in
            self?.unmuteAfterDebounce()
        }
    }

    /// Fired when `debounceSeconds` have elapsed since the last keystroke.
    /// Only unmutes if *we* were the ones who muted it, to avoid interfering
    /// with an external mute the user applied independently.
    private func unmuteAfterDebounce() {
        guard state == .muted else { return }
        if didWeMute {
            MicController.shared.unmute()
            didWeMute = false
        }
        state = .idle
        StatusBarController.shared.updateIcon()
    }

    // MARK: - Device change handling

    /// When the default input device changes mid-session, any in-flight mute
    /// state becomes invalid (the new device starts unmuted). Reset cleanly.
    private func handleDeviceChange() {
        if state == .muted {
            debounceTimer?.invalidate()
            didWeMute = false
            state = .idle
            StatusBarController.shared.updateIcon()
        }
    }

    // MARK: - Enable / disable

    /// Toggles Hushboard on or off. When disabling while muted, immediately
    /// restores the mic so the user isn't left silenced after pausing the app.
    func toggleEnabled() {
        isEnabled.toggle()
        isEnabledStored = isEnabled

        if isEnabled {
            state = AXIsProcessTrusted() ? .idle : .waitingPermission
        } else {
            if state == .muted && didWeMute {
                MicController.shared.unmute()
                didWeMute = false
            }
            debounceTimer?.invalidate()
            state = .disabled
        }
        StatusBarController.shared.updateIcon()
    }

    // MARK: - Daily statistics

    /// Key is date-scoped so counts reset automatically at midnight without
    /// any explicit cleanup logic.
    private var todayKey: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return "dailyMutes_\(f.string(from: Date()))"
    }

    private func loadTodayStats() {
        todayMuteCount = UserDefaults.standard.integer(forKey: todayKey)
    }

    private func incrementTodayStats() {
        let newCount = UserDefaults.standard.integer(forKey: todayKey) + 1
        UserDefaults.standard.set(newCount, forKey: todayKey)
        todayMuteCount = newCount
    }

    // MARK: - Teardown

    /// Called from `applicationWillTerminate`. Ensures the mic is unmuted and
    /// all timers are invalidated before the process exits.
    func teardown() {
        debounceTimer?.invalidate()
        permissionPollTimer?.invalidate()
        KeyboardMonitor.shared.stop()
        if didWeMute {
            MicController.shared.unmute()
        }
    }
}
