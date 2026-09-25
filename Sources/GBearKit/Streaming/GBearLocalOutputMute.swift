import CoreAudio
import Foundation

/// Mutes the default system output while streaming so audio is heard on the phone, not the Mac speakers.
@MainActor
enum GBearLocalOutputMute {
    private struct SavedOutputState {
        let deviceID: AudioDeviceID
        let muteValue: UInt32?
        let volumeValue: Float32?
    }

    private static var savedState: SavedOutputState?
    private static var isMutedForStream = false

    static func setStreamingMuted(_ muted: Bool) {
        if muted {
            guard !isMutedForStream else { return }
            muteDefaultOutput()
            isMutedForStream = true
        } else {
            guard isMutedForStream else { return }
            restoreDefaultOutput()
            isMutedForStream = false
        }
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    private static func readMute(deviceID: AudioDeviceID) -> UInt32? {
        var mute: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &mute)
        guard status == noErr else { return nil }
        return mute
    }

    private static func writeMute(deviceID: AudioDeviceID, muted: UInt32) -> Bool {
        var value = muted
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        let status = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &value
        )
        return status == noErr
    }

    private static func readVolume(deviceID: AudioDeviceID) -> Float32? {
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        guard status == noErr else { return nil }
        return volume
    }

    private static func writeVolume(deviceID: AudioDeviceID, volume: Float32) -> Bool {
        var value = max(0, min(volume, 1))
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        let status = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Float32>.size),
            &value
        )
        return status == noErr
    }

    private static func muteDefaultOutput() {
        guard let deviceID = defaultOutputDeviceID() else {
            print("[GBearAudio] could not resolve default output device for mute")
            return
        }
        let priorMute = readMute(deviceID: deviceID)
        let priorVolume = readVolume(deviceID: deviceID)
        savedState = SavedOutputState(
            deviceID: deviceID,
            muteValue: priorMute,
            volumeValue: priorVolume
        )

        var applied = false
        if writeMute(deviceID: deviceID, muted: 1) {
            applied = true
        }
        if writeVolume(deviceID: deviceID, volume: 0) {
            applied = true
        }
        if applied {
            print("[GBearAudio] muted Mac default output for streaming (mute + volume)")
        } else {
            print("[GBearAudio] could not mute Mac default output — no supported mute/volume properties")
        }
    }

    private static func restoreDefaultOutput() {
        guard let saved = savedState else { return }
        if let mute = saved.muteValue {
            _ = writeMute(deviceID: saved.deviceID, muted: mute)
        }
        if let volume = saved.volumeValue {
            _ = writeVolume(deviceID: saved.deviceID, volume: volume)
        }
        savedState = nil
        print("[GBearAudio] restored Mac default output mute/volume state")
    }
}
