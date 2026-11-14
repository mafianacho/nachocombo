import AppKit
import CoreAudio
import NachoComboCore

/// App side of the `awake_*`, `dim_*`, `device_*`, `mouse_*`, `appswitch_*` and `calendar_*` tools (NACHO-150).
/// Every method runs on the main thread (`SettingsGadgetToolRunner` hops there). Only switches, numbers and device
/// names pass through; no content is read or logged.
final class SettingsGadgetsController: SettingsGadgetsPort {
    private let keepAwake: () -> KeepAwakeModule?
    private let dimModule: () -> FocusDimModule?
    private let devices: () -> DeviceControlModule?
    private let currentOptions: () -> GadgetOptions
    private let setOptions: (GadgetOptions) -> Void
    private let dimIntensity: () -> Double

    init(keepAwake: @escaping () -> KeepAwakeModule?, dim: @escaping () -> FocusDimModule?,
         devices: @escaping () -> DeviceControlModule?, options: @escaping () -> GadgetOptions,
         setOptions: @escaping (GadgetOptions) -> Void, dimIntensity: @escaping () -> Double) {
        self.keepAwake = keepAwake
        self.dimModule = dim
        self.devices = devices
        self.currentOptions = options
        self.setOptions = setOptions
        self.dimIntensity = dimIntensity
    }

    func options() -> GadgetOptions { currentOptions() }
    func apply(options: GadgetOptions) { setOptions(options) }

    // MARK: Keep Awake

    func awake() -> AwakeSnapshot {
        let o = currentOptions()
        guard let k = keepAwake() else {
            return AwakeSnapshot(holding: false, manual: false, secondsLeft: nil, reason: "Keep Awake is not available",
                                 keepDisplay: o.keepAwakeDisplay, powerOnly: o.keepAwakePowerOnly, batteryFloor: o.keepAwakeBatteryFloor)
        }
        let left = k.until.map { max(0, Int($0.timeIntervalSinceNow.rounded())) }
        return AwakeSnapshot(holding: k.decision.holds, manual: k.manual, secondsLeft: k.manual ? left : nil, reason: k.decision.text,
                             keepDisplay: o.keepAwakeDisplay, powerOnly: o.keepAwakePowerOnly, batteryFloor: o.keepAwakeBatteryFloor)
    }

    func awakeHold(minutes: Int) { keepAwake()?.hold(minutes: minutes); keepAwake()?.onChange?() }
    func awakeStop() { keepAwake()?.letSleep(); keepAwake()?.onChange?() }

    // MARK: Focus Dim

    func dim() -> DimSnapshot {
        let o = currentOptions()
        return DimSnapshot(paused: dimModule()?.paused ?? false, percent: Int((dimIntensity() * 100).rounded()),
                           scope: o.dimScope.rawValue, otherDisplays: o.dimOtherDisplays, onlyInSession: o.dimOnlyInSession)
    }

    func dimSetPaused(_ paused: Bool) {
        guard let d = dimModule(), d.isRunning, d.paused != paused else { return }
        d.togglePause()
    }

    // MARK: Device Control

    func device() -> DeviceSnapshot {
        guard let d = devices() else { return DeviceSnapshot(outputName: nil, volumePercent: nil, inputName: nil, micMuted: false) }
        return DeviceSnapshot(outputName: d.currentOutput?.name, volumePercent: d.outputVolume.map { Int(($0 * 100).rounded()) },
                              inputName: d.currentInput?.name, micMuted: d.micMuted)
    }

    func deviceSetOutput(volumePercent: Int?, muted: Bool?) -> (Bool, String) {
        let id = CoreAudioBridge.defaultDevice(input: false)
        guard id != AudioObjectID(kAudioObjectUnknown) else { return (false, "there is no sound output device") }
        var parts: [String] = []
        if let percent = volumePercent {
            CoreAudioBridge.setVolume(id, input: false, Float32(percent) / 100)
            guard let now = CoreAudioBridge.volume(id, input: false), abs(now - Float32(percent) / 100) < 0.02 else {
                return (false, "the current sound output has no volume control Nacho Combo can set")
            }
            parts.append("volume \(percent)%")
        }
        if let muted = muted {
            guard CoreAudioBridge.setMute(id, input: false, muted) else {
                return (false, "the current sound output has no mute switch Nacho Combo can set")
            }
            parts.append(muted ? "muted" : "unmuted")
        }
        devices()?.onChange?()
        return (true, "Sound output: " + parts.joined(separator: ", ") + ".")
    }

    func deviceSetMicMuted(_ muted: Bool) { devices()?.setMicMuted(muted) }
}
