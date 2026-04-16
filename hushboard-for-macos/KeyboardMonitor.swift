import CoreGraphics
import Foundation

/// Installs a system-wide CGEvent tap that watches for `keyDown` events and
/// fires callbacks consumed by `HushboardViewModel`.
///
/// ## Why a CGEvent tap?
/// A CGEvent tap at `.cgSessionEventTap` is the only API that delivers *every*
/// keyboard event regardless of which app has focus, including fullscreen apps,
/// games, and the login window. `NSEvent.addGlobalMonitorForEvents` is similar
/// but misses events when certain secure input modes are active.
///
/// ## `.listenOnly`: we never suppress keystrokes
/// The tap is installed as `.listenOnly`, which means events pass through to the
/// target application unmodified. Hushboard only observes; it never swallows or
/// alters keystrokes. This also avoids the entitlement requirements for filter taps.
///
/// ## Thread safety
/// The tap callback runs on the main `CFRunLoop` (added via `.commonModes`), so
/// all callbacks arrive on the main thread and are safe to call into SwiftUI state.
class KeyboardMonitor {

    static let shared = KeyboardMonitor()
    private init() {}

    // Retained so we can disable the tap on `stop()`.
    var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Fired on every `keyDown` that is *not* the global toggle hotkey.
    var onKeyActivity: (() -> Void)?

    /// Fired when the user presses the global toggle hotkey (⌥⌘H).
    /// The hotkey press is not forwarded to `onKeyActivity`.
    var onHotkeyTriggered: (() -> Void)?

    // MARK: - Start

    func start() {
        guard eventTap == nil else { return }

        // Listen for both keyDown and keyUp so we can re-enable a disabled tap
        // in the `.tapDisabledByTimeout` / `.tapDisabledByUserInput` path below.
        let eventsOfInterest: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)

        // Pass `self` as unretained; the tap callback must not form a retain
        // cycle. The `KeyboardMonitor` singleton lives for the process lifetime,
        // so the raw pointer remains valid for the entire tap duration.
        let selfPtr = Unmanaged.passRetained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventsOfInterest,
            callback: { proxy, type, event, userInfo -> Unmanaged<CGEvent>? in
                guard let userInfo else { return Unmanaged.passRetained(event) }
                let monitor = Unmanaged<KeyboardMonitor>
                    .fromOpaque(userInfo)
                    .takeUnretainedValue()

                if type == .keyDown {
                    let flags   = event.flags
                    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

                    // Keycode 4 = H on all standard keyboard layouts.
                    // ⌥⌘H is the global toggle shortcut; it deliberately skips
                    // `onKeyActivity` so toggling Hushboard off doesn't itself
                    // trigger a mute.
                    if keyCode == 4
                        && flags.contains(.maskAlternate)
                        && flags.contains(.maskCommand)
                    {
                        DispatchQueue.main.async { monitor.onHotkeyTriggered?() }
                    } else {
                        monitor.onKeyActivity?()
                    }
                }

                // macOS can disable the tap if it detects the callback is too
                // slow or if the process loses Accessibility trust at runtime.
                // Re-enabling here keeps monitoring alive without requiring a relaunch.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = monitor.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                }

                return Unmanaged.passRetained(event)
            },
            userInfo: selfPtr
        ) else {
            // This path is only reached when Accessibility permission is absent.
            // `HushboardViewModel.startPermissionPolling()` will retry via
            // `startMonitoring()` once the user grants access.
            print("KeyboardMonitor: failed to create event tap — Accessibility permission required.")
            return
        }

        eventTap      = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    // MARK: - Stop

    /// Disables and removes the event tap. Called from `HushboardViewModel.teardown()`
    /// on app termination, ensuring no stale callbacks fire after the process exits.
    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap      = nil
        runLoopSource = nil
    }
}
