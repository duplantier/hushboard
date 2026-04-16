# Hushboard

**Automatically mutes your microphone while you type. No shortcuts to remember.**

Hushboard runs silently in the menu bar and listens for keyboard activity. The moment you start typing during a call, it mutes your mic. When you stop, it unmutes after a short configurable delay to catch trailing keystrokes.

---

## Features

- **Automatic mute on typing:** uses a CoreGraphics event tap to detect keystrokes globally
- **Configurable unmute delay:** 0.1 s to 1.5 s, so trailing keystrokes don't bleed through
- **Floating HUD:** always-on-top circle button that stays visible even when the menu bar is hidden in fullscreen meetings; click it for a management menu
- **Meeting-aware HUD visibility:** HUD appears only when a meeting app is running or a browser has a meeting tab active
- **Browser meeting detection:** detects Google Meet, Zoom web, Teams, Webex, Jitsi, Whereby via window title and tab URL (Chrome, Firefox, Safari, Arc, Brave, Edge, Opera, Vivaldi)
- **Pulse animation:** menu bar icon pulses red while the mic is muted
- **Launch at login:** registers via `SMAppService` (macOS 13+)
- **Global hotkey:** `⌥⌘H` toggles Hushboard on/off from anywhere
- **Crash recovery:** clears any hardware mute flag left from a previous session on launch

### Supported meeting apps

Zoom, Microsoft Teams (classic + new), Google Meet, FaceTime, Cisco Webex, Slack (huddles), Discord, Skype, Loom, BlueJeans, GoToMeeting, RingCentral, Whereby, Amazon Chime, Screen Studio, plus any browser-based meeting.

---

## Requirements

- macOS 13.0 or later
- Xcode 15 or later (to build from source)
- **Accessibility permission:** required for the global keyboard event tap

---

## Building from Source

1. Clone the repo:
   ```sh
   git clone https://github.com/huseyinkaratas/hushboard-for-macos.git
   cd hushboard-for-macos
   ```
2. Open `hushboard-for-macos.xcodeproj` in Xcode.
3. Select your development team in **Signing & Capabilities**.
4. Build and run (`⌘R`).
5. On first launch, grant **Accessibility** access when prompted (System Settings → Privacy & Security → Accessibility).

> No third-party dependencies required.

---

## How It Works

| Component | Role |
|---|---|
| `KeyboardMonitor` | CGEvent tap listening for `keyDown` events system-wide |
| `HushboardViewModel` | State machine: `idle → muted → idle`, debounce timer |
| `MicController` | CoreAudio HAL: sets `kAudioDevicePropertyMute` on the default input device |
| `MeetingDetector` | Checks running apps + browser AX tree for active meetings |
| `FloatingHUDController` | Always-on-top `NSPanel` with SwiftUI HUD and management menu |
| `StatusBarController` | Menu bar icon + popover with stats and settings |

### Why `kAudioDevicePropertyMute` and not volume?

On Apple Silicon Macs, `kAudioDevicePropertyVolumeScalar` at the input scope is the *input monitoring* level; it's already 0.0 by default and does **not** silence what apps record. Only the hardware mute flag (`kAudioDevicePropertyMute`) actually stops audio from reaching recording apps. Hushboard uses the mute flag as the primary mechanism, with a volume-zeroing fallback for hardware that lacks a settable mute property.

---

## Permissions

| Permission | Why |
|---|---|
| **Accessibility** | Global keyboard event tap via CoreGraphics |
| **Microphone** | CoreAudio mute/unmute of the default input device |

Hushboard is **not sandboxed**, which is required for a global event tap outside of the app's own windows.

---

## Contributing

Pull requests are welcome. For large changes, open an issue first to discuss the direction.

1. Fork the repo
2. Create a branch (`git checkout -b feature/your-feature`)
3. Commit your changes
4. Open a pull request

---

## License

MIT. See [LICENSE](LICENSE).
