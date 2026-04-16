import SwiftUI
import AppKit

// MARK: - Window controller

/// Creates and presents the onboarding window on first launch.
///
/// The window uses `.fullSizeContentView` with a transparent title bar so the
/// SwiftUI `OnboardingView` can fill the entire chrome-free window surface.
/// `isMovableByWindowBackground = true` lets the user drag the window from any
/// point in the view, which is important when there's no visible title bar to grab.
class OnboardingWindowController: NSWindowController {

    static func show() {
        guard #available(macOS 14.0, *) else { return }

        let view = OnboardingView {
            // Mark onboarding complete so subsequent launches skip directly to
            // `requestAccessibilityPermissionIfNeeded()` in `AppDelegate`.
            UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
            NSApp.windows.first { $0.title == "Welcome to Hushboard" }?.close()
        }

        let hosting = NSHostingController(rootView: view)
        let window  = NSWindow(contentViewController: hosting)
        window.title                       = "Welcome to Hushboard"
        window.styleMask                   = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent  = true
        window.isMovableByWindowBackground = true
        window.center()
        window.setContentSize(NSSize(width: 380, height: 420))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Onboarding view

/// Three-step wizard shown once on first launch.
///
/// Step 0: Welcome, app overview and feature summary
/// Step 1: Permission, guides the user to grant Accessibility access
/// Step 2: Done, confirms setup and reveals the global hotkey tip
///
/// We use a manual step counter (via `@State var step`) rather than a
/// `NavigationStack` because each step has a distinct layout; a linear
/// progression from 0→1→2 with no back navigation needed.
@available(macOS 14.0, *)
struct OnboardingView: View {
    var onComplete: () -> Void
    @State private var step = 0

    var body: some View {
        VStack(spacing: 0) {
            switch step {
            case 0:  welcomeStep
            case 1:  permissionStep
            default: doneStep
            }
        }
        .frame(width: 380, height: 420)
        .background(.regularMaterial)
    }

    // MARK: Step 0 - Welcome

    private var welcomeStep: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.bottom, 4)

            VStack(spacing: 8) {
                Text("Hushboard")
                    .font(.system(size: 24, weight: .bold))
                Text("type quietly. speak freely.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                featureRow(icon: "keyboard",       color: .blue,   text: "Detects when you start typing")
                featureRow(icon: "mic.slash.fill",  color: .red,    text: "Instantly mutes your microphone")
                featureRow(icon: "timer",           color: .orange, text: "Unmutes automatically when you stop")
            }
            .padding(.horizontal, 32)

            Spacer()

            Button("Get Started") { withAnimation { step = 1 } }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.bottom, 32)
        }
    }

    // MARK: Step 1 - Permission

    private var permissionStep: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.15))
                    .frame(width: 80, height: 80)
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.orange)
            }

            VStack(spacing: 8) {
                Text("Accessibility Access")
                    .font(.system(size: 20, weight: .bold))
                // Proactively address the privacy concern: keystrokes are never
                // logged or transmitted; the event tap only fires the mute callback.
                Text("Hushboard needs Accessibility permission to detect keystrokes system-wide. Your keystrokes are never logged or transmitted.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()

            VStack(spacing: 10) {
                Button("Open Accessibility Settings") {
                    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                // macOS doesn't post a reliable notification when TCC access is
                // granted to a running process, so we ask the user to confirm
                // manually. `startMonitoring()` will poll `AXIsProcessTrusted()`
                // and proceed as soon as the grant is detected.
                Button("I've granted access — Continue") {
                    withAnimation { step = 2 }
                    HushboardViewModel.shared.startMonitoring()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            .padding(.bottom, 32)
        }
    }

    // MARK: Step 2 - Done

    private var doneStep: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.15))
                    .frame(width: 80, height: 80)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.green)
            }

            VStack(spacing: 8) {
                Text("You're all set!")
                    .font(.system(size: 20, weight: .bold))
                Text("Hushboard is now running in your menu bar. Right-click the icon to toggle, or left-click for settings.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            // Monospaced code-style pill for the hotkey hint; makes it feel
            // distinct and scannable rather than blending into body text.
            Text("Tip: press ⌥⌘H anywhere to toggle on/off.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 28)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.secondary.opacity(0.1))
                )

            Spacer()

            Button("Start Using Hushboard") { onComplete() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.bottom, 32)
        }
    }

    // MARK: Helper

    private func featureRow(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 24)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}
