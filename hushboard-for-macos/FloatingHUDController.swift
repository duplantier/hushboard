import AppKit
import SwiftUI

/// Manages a small always-on-top floating button that remains visible even when
/// the menu bar is hidden (fullscreen apps) or obscured by other status-bar icons.
///
/// ## Why an NSPanel?
/// `NSPanel` with `.nonactivatingPanel` doesn't steal key focus when tapped,
/// which is critical: tapping the HUD during a call must not un-focus the
/// meeting window. A regular `NSWindow` would steal focus and potentially mute
/// the user's mic input in the conferencing app.
///
/// ## Collection behavior flags
/// - `.canJoinAllSpaces`: visible on every Space and fullscreen app desktop
/// - `.fullScreenAuxiliary`: renders above fullscreen app chrome (menu bar + Dock areas)
/// - `.stationary`: doesn't move during Space transitions (Mission Control animations)
///
/// ## Transparent background
/// The panel uses `.borderless` style with a clear background. `NSHostingView`
/// has its own CALayer that defaults to the system window background color, so
/// we must explicitly zero that layer's `backgroundColor` after setting the root view.
///
/// ## Drag-to-reposition
/// `isMovableByWindowBackground = true` lets the user drag the panel by clicking
/// any part of the window background. SwiftUI's `.onTapGesture` receives a tap
/// only when the pointer doesn't move, so tap-to-open-menu and drag-to-move
/// coexist without conflict.
class FloatingHUDController {

    static let shared = FloatingHUDController()
    private init() {}

    private var panel: NSPanel?
    /// Polls `MeetingDetector` every 5 seconds to show/hide the HUD as the
    /// user enters and leaves meetings.
    private var meetingPollTimer: Timer?

    // MARK: - Setup / teardown

    func setup() {
        createPanel()
        startMeetingPolling()
    }

    func teardown() {
        meetingPollTimer?.invalidate()
        meetingPollTimer = nil
        panel?.close()
        panel = nil
    }

    // MARK: - Panel creation

    private func createPanel() {
        let size = NSSize(width: 52, height: 52)

        let p = NSPanel(
            contentRect: NSRect(origin: restoredOrigin(for: size), size: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        p.level                      = .floating
        p.collectionBehavior         = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isOpaque                   = false
        p.backgroundColor            = .clear
        // System shadow renders around the panel's rectangular bounds, not the
        // circular SwiftUI view, producing the ugly square shadow seen before.
        // Disable it and let SwiftUI's `.shadow` modifier clip to the circle shape.
        p.hasShadow                  = false
        p.isMovableByWindowBackground = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidMove(_:)),
            name: NSWindow.didMoveNotification,
            object: p
        )

        let content = HUDView(onTap: { [weak self] in self?.showMenu() })
            .environmentObject(HushboardViewModel.shared)

        let hostingView = NSHostingView(rootView: content)
        // NSHostingView's CALayer defaults to the system window background color.
        // Clearing it makes the layer fully transparent so only the SwiftUI
        // circle is visible against the desktop.
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        p.contentView = hostingView
        self.panel    = p
    }

    // MARK: - In-meeting management menu

    /// Shows a contextual `NSMenu` positioned just above the HUD button.
    /// Using `NSMenu.popUp(positioning:at:in:)` rather than `NSStatusItem.menu`
    /// because the HUD is a panel, not a status item. The positioning API handles
    /// screen-edge flipping automatically.
    func showMenu() {
        guard let contentView = panel?.contentView else { return }
        let menu = buildMenu()
        menu.popUp(
            positioning: menu.items.first,
            at: NSPoint(x: 0, y: contentView.bounds.height + 6),
            in: contentView
        )
    }

    private func buildMenu() -> NSMenu {
        let vm   = HushboardViewModel.shared
        let menu = NSMenu()
        menu.autoenablesItems = false

        // ── Status header (read-only) ────────────────────────────────────────
        let statusItem = NSMenuItem(title: stateLabel(vm.state), action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        statusItem.image     = stateImage(vm.state)
        menu.addItem(statusItem)

        menu.addItem(.separator())

        // ── Toggle Hushboard on / off ────────────────────────────────────────
        let toggleTitle = vm.isEnabled ? "Pause Hushboard" : "Resume Hushboard"
        let toggleIcon  = vm.isEnabled ? "pause.circle"    : "play.circle"
        menu.addItem(NSMenuItem.action(title: toggleTitle, systemImage: toggleIcon) {
            HushboardViewModel.shared.toggleEnabled()
        })

        // ── Unmute delay submenu ─────────────────────────────────────────────
        // 0.1–1.5 s in 0.1 s steps. We format each value to one decimal place
        // before converting back to Double to avoid floating-point accumulation
        // errors (e.g. stride producing 0.30000000000000004).
        let delayOptions = stride(from: 0.1, through: 1.5, by: 0.1)
            .map { Double(String(format: "%.1f", $0))! }
        let delayMenu = NSMenu()
        for val in delayOptions {
            let label = String(format: "%.1f seconds", val)
            let item  = NSMenuItem.action(title: label) {
                HushboardViewModel.shared.debounceSeconds = val
            }
            // Epsilon comparison avoids false mismatches from floating-point drift.
            item.state = abs(vm.debounceSeconds - val) < 0.01 ? .on : .off
            delayMenu.addItem(item)
        }
        let delayTitle = String(format: "Unmute Delay: %.1f s", vm.debounceSeconds)
        let delayItem  = NSMenuItem(title: delayTitle, action: nil, keyEquivalent: "")
        delayItem.submenu = delayMenu
        delayItem.image   = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)
        menu.addItem(delayItem)

        menu.addItem(.separator())

        // ── Launch at login ──────────────────────────────────────────────────
        let loginItem = NSMenuItem.action(title: "Launch at Login") {
            HushboardViewModel.shared.launchAtLogin.toggle()
            LoginItemManager.shared.setEnabled(HushboardViewModel.shared.launchAtLogin)
        }
        loginItem.state = vm.launchAtLogin ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())

        // ── Quit ─────────────────────────────────────────────────────────────
        menu.addItem(NSMenuItem.action(title: "Quit Hushboard", systemImage: "power") {
            NSApp.terminate(nil)
        })

        return menu
    }

    // MARK: - Menu helpers

    private func stateLabel(_ state: HushboardState) -> String {
        switch state {
        case .disabled:          return "Hushboard is Off"
        case .waitingPermission: return "Needs Accessibility Access"
        case .idle:              return "Hushboard is Live"
        case .muted:             return "Mic Muted — Typing Detected"
        }
    }

    private func stateImage(_ state: HushboardState) -> NSImage? {
        let name: String
        switch state {
        case .disabled:          name = "mic.slash"
        case .waitingPermission: name = "exclamationmark.triangle"
        case .idle:              name = "mic.fill"
        case .muted:             name = "mic.slash.fill"
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    // MARK: - Position persistence

    private static let hudXKey = "floatingHUDOriginX"
    private static let hudYKey = "floatingHUDOriginY"

    /// Returns the last saved panel origin, defaulting to the bottom-right corner
    /// of the main screen's visible frame if no saved position exists.
    private func restoredOrigin(for size: NSSize) -> NSPoint {
        let x = UserDefaults.standard.double(forKey: Self.hudXKey)
        let y = UserDefaults.standard.double(forKey: Self.hudYKey)
        if x != 0 || y != 0 { return NSPoint(x: x, y: y) }
        return defaultOrigin(for: size)
    }

    private func defaultOrigin(for size: NSSize) -> NSPoint {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let frame  = screen.visibleFrame
        // Bottom-right, 20 pt from each edge. Avoids the macOS Dock.
        return NSPoint(x: frame.maxX - size.width - 20, y: frame.minY + 20)
    }

    /// Persists the panel origin whenever the user repositions the HUD by dragging.
    @objc private func windowDidMove(_ note: Notification) {
        guard let origin = panel?.frame.origin else { return }
        UserDefaults.standard.set(origin.x, forKey: Self.hudXKey)
        UserDefaults.standard.set(origin.y, forKey: Self.hudYKey)
    }

    // MARK: - Meeting-aware visibility

    private func startMeetingPolling() {
        meetingPollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.syncVisibility()
        }
        // `.common` mode keeps the timer firing while NSMenu or other run-loop
        // sources are active (default mode pauses timers during tracking loops).
        RunLoop.main.add(meetingPollTimer!, forMode: .common)
        syncVisibility()
    }

    /// Shows the panel when a meeting is in progress; hides it otherwise.
    /// Dispatched to main because `orderFront`/`orderOut` must run on the main thread.
    func syncVisibility() {
        DispatchQueue.main.async { [weak self] in
            guard let panel = self?.panel else { return }
            if MeetingDetector.shared.isMeetingAppRunning {
                panel.orderFront(nil)
            } else {
                panel.orderOut(nil)
            }
        }
    }
}

// MARK: - NSMenuItem + closure actions

extension NSMenuItem {
    /// Creates a menu item backed by a Swift closure instead of a target/action pair.
    ///
    /// `NSMenu` requires an Objective-C target object, so we wrap the closure in a
    /// `ClosureMenuHandler` and retain it on the item itself via `objc_setAssociatedObject`.
    /// Without the associated-object retain, the handler would be released immediately
    /// after this factory returns, causing a crash when the item is selected.
    static func action(
        title: String,
        systemImage: String? = nil,
        _ closure: @escaping () -> Void
    ) -> NSMenuItem {
        let handler = ClosureMenuHandler(closure)
        let item    = NSMenuItem(title: title, action: #selector(ClosureMenuHandler.invoke), keyEquivalent: "")
        item.target  = handler
        item.isEnabled = true
        if let name = systemImage {
            item.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        }
        // Tie the handler's lifetime to the menu item so it stays alive as long
        // as the NSMenu exists.
        objc_setAssociatedObject(item, &ClosureMenuHandler.key, handler, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return item
    }
}

/// Objective-C–compatible wrapper that bridges a Swift closure to an `@objc` selector.
private class ClosureMenuHandler: NSObject {
    static var key: UInt8 = 0
    private let closure: () -> Void
    init(_ closure: @escaping () -> Void) { self.closure = closure }
    @objc func invoke() { closure() }
}

// MARK: - SwiftUI HUD view

/// The circular button rendered inside the floating panel.
///
/// Visual states mirror `HushboardState`:
/// - Gray  → disabled
/// - Orange → waiting for Accessibility permission
/// - Green  → monitoring active (idle)
/// - Red    → mic muted (typing detected)
///
/// The small `chevron.up` in the bottom-right corner signals to the user that
/// tapping opens a menu rather than performing an immediate action.
struct HUDView: View {
    @EnvironmentObject var vm: HushboardViewModel
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        ZStack {
            Circle()
                .fill(bgColor)
                // SwiftUI shadow clips to the circle shape, unlike NSPanel's system
                // shadow which renders around the rectangular window bounds.
                .shadow(color: .black.opacity(0.35), radius: isHovered ? 8 : 5, x: 0, y: 2)
            Image(systemName: iconName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
            // Subtle menu-affordance indicator
            Image(systemName: "chevron.up")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.white.opacity(0.6))
                .offset(x: 14, y: 14)
        }
        .frame(width: 48, height: 48)
        .scaleEffect(isHovered ? 1.08 : 1.0)
        .padding(2)           // prevents the shadow from clipping at the panel edge
        .contentShape(Circle())
        .onTapGesture { onTap() }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
            // Swap to a pointing-hand cursor so the button feels clickable.
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .animation(.easeInOut(duration: 0.2), value: vm.state)
        .help(helpText)
    }

    private var bgColor: Color {
        switch vm.state {
        case .disabled:          return Color(white: 0.4)
        case .waitingPermission: return .orange
        case .idle:              return Color(red: 0.18, green: 0.72, blue: 0.30)
        case .muted:             return .red
        }
    }

    private var iconName: String {
        switch vm.state {
        case .disabled:          return "mic.slash"
        case .waitingPermission: return "exclamationmark.triangle"
        case .idle:              return "mic.fill"
        case .muted:             return "mic.slash.fill"
        }
    }

    private var helpText: String {
        switch vm.state {
        case .disabled:          return "Hushboard is off — click for menu"
        case .waitingPermission: return "Hushboard needs Accessibility access"
        case .idle:              return "Hushboard is live — click for menu"
        case .muted:             return "Mic muted (typing) — click for menu"
        }
    }
}
