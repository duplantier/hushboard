import SwiftUI
import AppKit

/// Settings and status popover shown when the user left-clicks the menu bar icon.
///
/// Layout (top to bottom):
/// 1. **Status hero:** large icon + title/subtitle driven by `HushboardState`
/// 2. **Permission warning:** shown only in `.waitingPermission` state
/// 3. **Stats row:** session mutes, today's mutes, active input device name
/// 4. **Unmute delay slider:** 0.5 s to 1.5 s
/// 5. **Launch at login toggle**
/// 6. **Quit button:** with ⌘Q keyboard shortcut
@available(macOS 14.0, *)
struct PopoverView: View {
    @EnvironmentObject var vm: HushboardViewModel
    @State private var isHoveringCircle = false
    @State private var isHoveringQuit   = false

    var body: some View {
        VStack(spacing: 0) {

            // ── Status hero ───────────────────────────────────────────────
            VStack(spacing: 10) {
                // The circle button doubles as the primary enable/disable toggle.
                // Tapping it calls `toggleEnabled()` directly from the popover.
                Button {
                    vm.toggleEnabled()
                } label: {
                    ZStack {
                        Circle()
                            .fill(stateColor.opacity(isHoveringCircle ? 0.22 : 0.15))
                        Circle()
                            .strokeBorder(stateColor.opacity(isHoveringCircle ? 0.45 : 0.25), lineWidth: 1)
                        Image(systemName: stateSymbol)
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(stateColor)
                    }
                    .frame(width: 56, height: 56)
                    .scaleEffect(isHoveringCircle ? 1.06 : 1.0)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled(true)
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.15)) { isHoveringCircle = hovering }
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
                .animation(.easeInOut(duration: 0.2), value: vm.state)

                VStack(spacing: 3) {
                    Text(stateTitle)
                        .font(.system(size: 13, weight: .semibold))
                    Text(stateSubtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .animation(.easeInOut(duration: 0.15), value: vm.state)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 18)
            .padding(.bottom, 14)
            .padding(.horizontal, 20)

            // ── Permission warning ────────────────────────────────────────
            // Shown inline only when Accessibility hasn't been granted yet,
            // providing actionable remediation without leaving the popover.
            if vm.state == .waitingPermission {
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.system(size: 12))
                        Text("Needs Accessibility access")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Settings") { openAccessibilitySettings() }
                            .font(.system(size: 11))
                            .buttonStyle(.plain)
                            .tint(.accentColor)
                            .focusEffectDisabled(true)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text("Already granted?")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        // macOS doesn't automatically inform a running app that
                        // TCC was granted. The fastest path is a relaunch, which
                        // calls `AXIsProcessTrustedWithOptions` fresh on startup.
                        Button("Relaunch app") { relaunch() }
                            .font(.system(size: 10))
                            .buttonStyle(.plain)
                            .tint(.accentColor)
                            .focusEffectDisabled(true)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }

            Divider()

            // ── Stats row ─────────────────────────────────────────────────
            // Three equal-width cells separated by hairline dividers.
            // The device name uses `.middle` truncation to preserve the
            // distinctive suffix of long names like "MacBook Pro Microphone".
            HStack(spacing: 0) {
                statCell(value: "\(vm.muteCount)",      label: "this session")
                Divider().frame(height: 32)
                statCell(value: "\(vm.todayMuteCount)", label: "today")
                Divider().frame(height: 32)
                VStack(spacing: 2) {
                    Text(MicController.shared.defaultInputDeviceName())
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("active input")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 11)

            Divider()

            // ── Unmute delay slider ───────────────────────────────────────
            // 0.5–1.5 s range covers the practical tradeoff between
            // responsiveness (too low = mic audibly blips when pausing to think)
            // and latency (too high = teammates hear you before you realize you stopped typing).
            VStack(spacing: 5) {
                HStack {
                    Text("Unmute delay")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Text("\(vm.debounceSeconds, specifier: "%.1f")s")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $vm.debounceSeconds, in: 0.5...1.5, step: 0.1)
                    .tint(stateColor)
            }
            .padding(.horizontal, 14)
            .padding(.top, 11)
            .padding(.bottom, 6)

            Divider()

            // ── Launch at login ───────────────────────────────────────────
            HStack {
                Text("Launch at login")
                    .font(.system(size: 11))
                Spacer()
                Toggle("", isOn: $vm.launchAtLogin)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.mini)
                    .focusEffectDisabled(true)
                    .onChange(of: vm.launchAtLogin) { _, newVal in
                        LoginItemManager.shared.setEnabled(newVal)
                    }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            // ── Footer ────────────────────────────────────────────────────
            VStack(spacing: 0) {
                menuRow("Quit Hushboard", icon: "power", shortcut: "⌘Q",
                        isHovering: $isHoveringQuit) {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .frame(width: 290)
    }

    // MARK: - Stat cell

    private func statCell(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Menu-style row

    /// A button styled to look like an `NSMenuItem`, with hover highlight, icon,
    /// and right-aligned shortcut hint. Used in the popover footer.
    @ViewBuilder
    private func menuRow(
        _ title: String,
        icon: String? = nil,
        shortcut: String? = nil,
        isHovering: Binding<Bool>,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                        .foregroundStyle(isHovering.wrappedValue ? Color.primary : Color.secondary)
                        .frame(width: 14)
                }
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(isHovering.wrappedValue ? Color.primary : Color.secondary)
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovering.wrappedValue
                          ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.2)
                          : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled(true)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) { isHovering.wrappedValue = hovering }
        }
    }

    // MARK: - State-driven appearance

    private var stateColor: Color {
        switch vm.state {
        case .disabled:          return Color(red: 0.91, green: 0.89, blue: 0.85)
        case .waitingPermission: return .orange
        case .idle:              return .green
        case .muted:             return .red
        }
    }

    private var stateSymbol: String {
        switch vm.state {
        case .disabled:          return "mic.slash"
        case .waitingPermission: return "exclamationmark.triangle"
        case .idle:              return "mic.fill"
        case .muted:             return "mic.slash.fill"
        }
    }

    private var stateTitle: String {
        switch vm.state {
        case .disabled:          return "Hushboard is off"
        case .waitingPermission: return "Permission needed"
        case .idle:              return "Hushboard is live"
        case .muted:             return "Mic is muted"
        }
    }

    private var stateSubtitle: String {
        switch vm.state {
        case .disabled:          return "Tap the circle above to re-enable"
        case .waitingPermission: return "Grant Accessibility access below"
        case .idle:              return "Start typing to mute automatically"
        case .muted:             return "Unmutes \(String(format: "%.1f", vm.debounceSeconds))s after you stop typing"
        }
    }

    // MARK: - Actions

    private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// Relaunches the app by spawning a shell watcher that opens the bundle once
    /// the current process has fully exited. This is simpler and more reliable
    /// than `execve`-based relaunching, which can hit sandboxing restrictions.
    private func relaunch() {
        let pid        = ProcessInfo.processInfo.processIdentifier
        let bundlePath = Bundle.main.bundleURL.path
        let task       = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments     = ["-c",
            "while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; open '\(bundlePath)'"]
        try? task.run()
        NSApp.terminate(nil)
    }
}
