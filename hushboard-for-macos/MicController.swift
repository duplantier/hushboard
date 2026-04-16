import CoreAudio
import Foundation

/// Manages muting and unmuting the system's default audio input device via the
/// CoreAudio Hardware Abstraction Layer (HAL).
///
/// ## Why `kAudioDevicePropertyMute` Instead of `VolumeScalar`
///
/// On Apple Silicon Macs, `kAudioDevicePropertyVolumeScalar` at the input scope
/// is the *input monitoring* level; it controls how much of the mic signal is
/// routed back to the speakers for live monitoring. It is **not** the recording
/// gain; it defaults to 0.0 and changing it has no effect on what recording apps
/// actually capture. Only the hardware mute flag (`kAudioDevicePropertyMute = 1`)
/// silences the signal at the driver level, which is what apps like Zoom, Meet,
/// and Voice Memos read.
///
/// We confirmed this by correlating `osascript 'set volume input volume 0'`
/// against raw HAL property reads: only the mute flag changed, never the scalar.
///
/// The volume-scalar path is kept as a fallback for exotic USB/Bluetooth hardware
/// that may lack a settable mute property on any of its elements.
///
/// ## Element probing (0, 1, 2)
/// CoreAudio devices expose properties per *element*. Element 0 is the master
/// channel; 1 and 2 are individual channels (L/R). The built-in mic typically
/// exposes a settable mute only on element 0, but we probe all three to be safe.
class MicController {

    static let shared = MicController()

    private init() {
        // Restore a previously saved volume in case the app was killed mid-session
        // while using the volume-scalar fallback path.
        let stored = UserDefaults.standard.float(forKey: "hushboard_savedInputVolume")
        if stored > 0 { savedInputVolume = stored }
    }

    // MARK: - Startup recovery

    /// Clears any hardware mute flag that may have been left set by a previous
    /// session that crashed or was force-quit before `teardown()` ran.
    ///
    /// Called once at startup, before the keyboard monitor begins, so the mic
    /// is guaranteed to be in a clean unmuted state on every launch.
    func recoverIfNeeded() {
        guard let deviceID = defaultInputDeviceID() else { return }

        // Always clear the hardware mute flag unconditionally. If Hushboard
        // crashed while muted, this is the only mechanism that reliably restores
        // the mic on Apple Silicon. VolumeScalar alone doesn't help here.
        clearMuteFlag(deviceID: deviceID)

        // If a volume backup exists from a volume-scalar fallback in a prior run,
        // run through `setMute(false)` to restore it.
        if savedInputVolume != nil { setMute(false) }
    }

    // MARK: - Public API

    func mute()   { setMute(true)  }
    func unmute() { setMute(false) }

    /// Reads the current mute state from hardware.
    /// Returns `true` if the hardware mute flag is set, or (fallback) if the
    /// volume scalar is effectively zero on devices without a mute property.
    var isMuted: Bool { getMuteState() }

    // MARK: - Device change listener

    private var deviceListenerActive = false

    /// Registers a CoreAudio property listener that fires whenever the default
    /// input device changes (USB mic plugged in, Bluetooth headset connected, etc.).
    /// The callback is delivered on the main queue for safe UI updates.
    func startListeningForDeviceChanges(onChange: @escaping () -> Void) {
        guard !deviceListenerActive else { return }
        deviceListenerActive = true

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main
        ) { _, _ in onChange() }
    }

    // MARK: - Device name

    /// Returns the localized name of the current default input device.
    /// Used in the popover stats row to show which mic is active.
    func defaultInputDeviceName() -> String {
        guard let deviceID = defaultInputDeviceID() else { return "Unknown" }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var nameRef: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &nameRef)
        guard status == noErr, let name = nameRef?.takeRetainedValue() else { return "Unknown" }
        return name as String
    }

    // MARK: - Capability checks (used by PopoverView)

    /// True if the default input device has at least one settable VolumeScalar element.
    func inputDeviceSupportsVolume() -> Bool {
        guard let deviceID = defaultInputDeviceID() else { return false }
        return !settableVolumeElements(deviceID: deviceID).isEmpty
    }

    /// True if the default input device has a settable hardware mute property.
    func inputDeviceSupportsMute() -> Bool {
        guard let deviceID = defaultInputDeviceID() else { return false }
        return muteElement(deviceID: deviceID) != nil
    }

    // MARK: - Core mute logic

    /// Persisted across launches so the volume-scalar fallback can restore the
    /// original level after a crash. Persisted to `UserDefaults` on every write
    /// so a force-quit doesn't lose the saved value.
    private var savedInputVolume: Float32? = nil {
        didSet {
            if let v = savedInputVolume {
                UserDefaults.standard.set(v, forKey: "hushboard_savedInputVolume")
            } else {
                UserDefaults.standard.removeObject(forKey: "hushboard_savedInputVolume")
            }
        }
    }

    private func setMute(_ muted: Bool) {
        guard let deviceID = defaultInputDeviceID() else { return }

        // ── Primary path: hardware mute flag ────────────────────────────────
        // Atomic, instant, and the only mechanism that reliably silences
        // recording on Apple Silicon. See class-level doc for full rationale.
        if let element = muteElement(deviceID: deviceID) {
            var muteValue: UInt32 = muted ? 1 : 0
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: element
            )
            AudioObjectSetPropertyData(deviceID, &address, 0, nil,
                                       UInt32(MemoryLayout<UInt32>.size), &muteValue)
            return
        }

        // ── Fallback: zero the input volume scalar ───────────────────────────
        // Only reached on hardware without a settable mute property.
        // We save the current volume before zeroing so we can restore it exactly.
        let volElements = settableVolumeElements(deviceID: deviceID)
        guard !volElements.isEmpty else { return }

        if muted {
            let current = readVolume(element: volElements[0], deviceID: deviceID)
            if current > 0 { savedInputVolume = current }
            for el in volElements { writeVolume(0.0, element: el, deviceID: deviceID) }
        } else {
            let restore = savedInputVolume ?? 1.0
            for el in volElements { writeVolume(restore, element: el, deviceID: deviceID) }
            savedInputVolume = nil
        }
    }

    private func getMuteState() -> Bool {
        guard let deviceID = defaultInputDeviceID() else { return false }

        // Check the hardware mute flag first, consistent with the primary
        // write path so reads and writes agree on the same property.
        if let element = muteElement(deviceID: deviceID) {
            var muteValue: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: element
            )
            let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muteValue)
            if status == noErr { return muteValue == 1 }
        }

        // Volume-scalar fallback for devices without a mute property.
        let volElements = settableVolumeElements(deviceID: deviceID)
        if let first = volElements.first {
            return readVolume(element: first, deviceID: deviceID) < 0.01
        }

        return false
    }

    // MARK: - Property helpers

    /// Returns the first element index (0, 1, or 2) that has a settable mute
    /// property at the input scope, or `nil` if no such element exists.
    private func muteElement(deviceID: AudioDeviceID) -> UInt32? {
        for element: UInt32 in [0, 1, 2] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: element
            )
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            var settable: DarwinBoolean = false
            AudioObjectIsPropertySettable(deviceID, &address, &settable)
            if settable.boolValue { return element }
        }
        return nil
    }

    /// Clears the hardware mute flag on every input element that has one.
    /// Used during crash recovery to ensure the mic isn't stuck silenced.
    private func clearMuteFlag(deviceID: AudioDeviceID) {
        for element: UInt32 in [0, 1, 2] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: element
            )
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            var settable: DarwinBoolean = false
            AudioObjectIsPropertySettable(deviceID, &address, &settable)
            guard settable.boolValue else { continue }
            var muteValue: UInt32 = 0
            AudioObjectSetPropertyData(deviceID, &address, 0, nil,
                                       UInt32(MemoryLayout<UInt32>.size), &muteValue)
        }
    }

    /// Returns all element indices that have a settable `VolumeScalar` at the
    /// input scope. Used only by the volume-scalar fallback path.
    private func settableVolumeElements(deviceID: AudioDeviceID) -> [UInt32] {
        var result: [UInt32] = []
        for element: UInt32 in [0, 1, 2] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: element
            )
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            var settable: DarwinBoolean = false
            AudioObjectIsPropertySettable(deviceID, &address, &settable)
            if settable.boolValue { result.append(element) }
        }
        return result
    }

    private func readVolume(element: UInt32, deviceID: AudioDeviceID) -> Float32 {
        var volume: Float32 = 1.0
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: element
        )
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        return volume
    }

    private func writeVolume(_ volume: Float32, element: UInt32, deviceID: AudioDeviceID) {
        var vol = volume
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: element
        )
        AudioObjectSetPropertyData(deviceID, &address, 0, nil,
                                   UInt32(MemoryLayout<Float32>.size), &vol)
    }

    // MARK: - Default input device

    /// Resolves the `AudioDeviceID` of the current system default input device.
    /// Returns `nil` if no input device is available (e.g. on a Mac mini with no
    /// mic plugged in and no Bluetooth headset connected).
    private func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }
}
