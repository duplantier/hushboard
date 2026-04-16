import AppKit
import SwiftUI

/// Owns the `NSStatusItem` (menu bar icon) and the settings popover.
///
/// ## Icon tinting strategy
/// We create a tinted `NSImage` at runtime rather than shipping separate icon
/// assets for each state. The tint is applied by drawing the SF Symbol and then
/// filling with `.sourceAtop` compositing to colorize only the opaque pixels.
/// `isTemplate = false` disables AppKit's automatic template-mode darkening so
/// our explicit color is used as-is.
///
/// ## Click handling
/// - Left-click → toggle the settings popover
/// - Right-click → toggle Hushboard on/off (quick access without opening the popover)
///
/// ## Pulse animation
/// In the `.muted` state the icon pulses between alpha 0.4 and 1.0 using a
/// 50 ms timer. This draws the user's eye to the fact that the mic is muted
/// without requiring them to focus on the icon continuously.
class StatusBarController {

    static let shared = StatusBarController()
    private init() {}

    private var statusItem: NSStatusItem?
    private var popover:    NSPopover?

    // Pulse state, only active while `HushboardState == .muted`.
    private var pulseTimer:  Timer?
    private var pulseAlpha:  CGFloat = 1.0
    private var pulseRising: Bool    = false

    // MARK: - Setup

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.action = #selector(handleClick)
            button.target = self
            // Receive both left- and right-click events on the button.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Hushboard"
        }

        // Build the popover content. The `@available` guard is needed because
        // `PopoverView` uses APIs introduced in macOS 14 (e.g. `onChange(of:)`
        // with two-argument closure). Older macOS sees a plain text fallback.
        let popoverView: AnyView
        if #available(macOS 14.0, *) {
            popoverView = AnyView(
                PopoverView()
                    .environmentObject(HushboardViewModel.shared)
            )
        } else {
            popoverView = AnyView(
                Text("Hushboard requires macOS 14 or later for the popover UI.")
                    .padding()
            )
        }

        let popoverVC    = NSHostingController(rootView: popoverView)
        popover          = NSPopover()
        popover?.contentViewController = popoverVC
        // `.transient` closes the popover when the user clicks outside it,
        // matching standard macOS menu-bar app behavior.
        popover?.behavior    = .transient
        popover?.contentSize = NSSize(width: 290, height: 360)

        updateIcon()
    }

    // MARK: - Click handler

    @objc func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            // Right-click as a fast path to toggle without opening the popover.
            HushboardViewModel.shared.toggleEnabled()
        } else {
            togglePopover(sender)
        }
    }

    func togglePopover(_ sender: NSStatusBarButton) {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            // `activate` is needed so the popover can receive keyboard events
            // (e.g. ⌘Q in the popover's footer row).
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Icon update

    /// Rebuilds the status-item image and starts/stops the pulse animation.
    /// Must be called on the main thread (dispatched internally).
    func updateIcon() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.statusItem?.button?.image   = self.iconImage()
            self.statusItem?.button?.toolTip = self.tooltipText

            if HushboardViewModel.shared.state == .muted {
                self.startPulse()
            } else {
                self.stopPulse()
            }
        }
    }

    // MARK: - Pulse animation

    private func startPulse() {
        guard pulseTimer == nil else { return }
        pulseAlpha  = 1.0
        pulseRising = false
        pulseTimer  = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.pulseRising {
                self.pulseAlpha = min(1.0, self.pulseAlpha + 0.04)
                if self.pulseAlpha >= 1.0 { self.pulseRising = false }
            } else {
                self.pulseAlpha = max(0.4, self.pulseAlpha - 0.04)
                if self.pulseAlpha <= 0.4 { self.pulseRising = true }
            }
            self.statusItem?.button?.alphaValue = self.pulseAlpha
        }
    }

    private func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        // Restore full opacity when the pulse stops.
        statusItem?.button?.alphaValue = 1.0
    }

    // MARK: - Icon image

    private func iconImage() -> NSImage? {
        let vm         = HushboardViewModel.shared
        let symbolName: String
        let tint:       NSColor

        switch vm.state {
        case .disabled:
            symbolName = "mic.slash"
            tint = NSColor(red: 0.91, green: 0.89, blue: 0.85, alpha: 1.0)
        case .waitingPermission:
            symbolName = "exclamationmark.triangle"
            tint = .systemOrange
        case .idle:
            symbolName = "mic"
            tint = .labelColor   // adapts to light/dark menu bar automatically
        case .muted:
            symbolName = "mic.slash.fill"
            tint = .systemRed
        }

        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        guard let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }

        // Draw the symbol, then overlay the tint color using `.sourceAtop`
        // compositing so only the opaque symbol pixels are colorized.
        let tinted = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        // Disable template mode so AppKit doesn't override our tint with a
        // system monochrome treatment in dark menu bars.
        tinted.isTemplate = false
        return tinted
    }

    // MARK: - Tooltip text

    private var tooltipText: String {
        switch HushboardViewModel.shared.state {
        case .disabled:          return "Hushboard — Off (right-click to enable)"
        case .waitingPermission: return "Hushboard — Needs Accessibility permission"
        case .idle:              return "Hushboard — Live  •  ⌥⌘H to toggle"
        case .muted:             return "Hushboard — Mic muted (typing detected)"
        }
    }
}
