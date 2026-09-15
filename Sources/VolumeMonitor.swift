import CoreAudio
import AudioToolbox
import Foundation

/// Watches system output volume/mute. A change that nobody made with the volume keys,
/// while the mouse was busy, was almost certainly a slider drag in Control Center.
final class VolumeMonitor {
    enum Change { case up, down, muteToggled }

    var onChange: ((Change) -> Void)?

    private let queue = DispatchQueue(label: "ShortcutCoach.Volume")
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var lastVolume: Float32 = -1
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    private static let virtualMainVolume = AudioObjectPropertySelector(0x766D_7663) // 'vmvc'

    func start() {
        queue.async { [weak self] in
            self?.attachDefaultDeviceListener()
            self?.bindCurrentDevice()
        }
    }

    private func address(_ selector: AudioObjectPropertySelector,
                         _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private func attachDefaultDeviceListener() {
        let addr = address(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.bindCurrentDevice() }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), [addr], queue, block) == noErr {
            listeners.append((AudioObjectID(kAudioObjectSystemObject), addr, block))
        }
    }

    private func bindCurrentDevice() {
        for (object, addr, block) in listeners where object != AudioObjectID(kAudioObjectSystemObject) {
            AudioObjectRemovePropertyListenerBlock(object, [addr], queue, block)
        }
        listeners.removeAll { $0.0 != AudioObjectID(kAudioObjectSystemObject) }

        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else { return }

        device = deviceID
        lastVolume = readVolume() ?? -1

        let volumeAddr = address(Self.virtualMainVolume)
        let volumeBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.volumeChanged() }
        if AudioObjectAddPropertyListenerBlock(deviceID, [volumeAddr], queue, volumeBlock) == noErr {
            listeners.append((deviceID, volumeAddr, volumeBlock))
        }

        let muteAddr = address(kAudioDevicePropertyMute)
        let muteBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onChange?(.muteToggled) }
        if AudioObjectAddPropertyListenerBlock(deviceID, [muteAddr], queue, muteBlock) == noErr {
            listeners.append((deviceID, muteAddr, muteBlock))
        }
    }

    private func readVolume() -> Float32? {
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var addr = address(Self.virtualMainVolume)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private func volumeChanged() {
        guard let value = readVolume() else { return }
        let previous = lastVolume
        lastVolume = value
        guard previous >= 0, abs(value - previous) > 0.0005 else { return }
        onChange?(value > previous ? .up : .down)
    }
}
