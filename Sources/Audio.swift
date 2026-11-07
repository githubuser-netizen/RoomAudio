import Foundation
import CoreAudio
import AVFoundation

func checked(_ status: OSStatus, _ operation: String) throws {
    if status != noErr { throw NSError(domain: "RoomAudio", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "\(operation) failed (\(status)). Check System Settings → Privacy & Security → System Audio Recording, then reopen RoomAudio."]) }
}
func audioError(_ message: String) -> NSError { NSError(domain: "RoomAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
func now() -> Double { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }
func ticks(_ seconds: Double) -> UInt64 { AVAudioTime.hostTime(forSeconds: max(0, seconds)) }

struct SpotifyProcesses {
    static func includes(bundle: String) -> Bool {
        bundle == "com.spotify.client" || bundle.hasPrefix("com.spotify.client.")
    }
    static func current() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        var size: UInt32 = 0
        try checked(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size), "Find Spotify audio processes")
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard !ids.isEmpty else { return [] }
        try checked(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids), "Read Spotify audio processes")
        return ids.filter { id in
            var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
            var reference: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &reference) == noErr,
                  let bundle = reference?.takeRetainedValue() else { return false }
            return includes(bundle: bundle as String)
        }.sorted()
    }
}

struct StereoPCM {
    let data: Data
    let frames: Int
    // IOProc buffer layout can differ from the tap description. Trust channel counts,
    // never infer planar/interleaved layout from the tap's cached format flags.
    static func copy(_ buffers: UnsafeMutableAudioBufferListPointer) -> StereoPCM? {
        guard let first = buffers.first, let a = first.mData, first.mDataByteSize > 0 else { return nil }
        if buffers.count == 1, first.mNumberChannels == 2 {
            guard first.mDataByteSize % 8 == 0 else { return nil }
            let frames = Int(first.mDataByteSize) / 8
            guard frames <= 16384 else { return nil }
            return StereoPCM(data: Data(bytes: a, count: frames * 8), frames: frames)
        }
        guard buffers.count == 2, first.mNumberChannels == 1,
              buffers[1].mNumberChannels == 1, let b = buffers[1].mData,
              first.mDataByteSize == buffers[1].mDataByteSize,
              first.mDataByteSize % 4 == 0 else { return nil }
        let frames = Int(first.mDataByteSize) / 4
        guard frames <= 16384 else { return nil }
        var data = Data(count: frames * 8)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Float.self)
            let left = a.assumingMemoryBound(to: Float.self), right = b.assumingMemoryBound(to: Float.self)
            for i in 0..<frames { out[2*i] = left[i]; out[2*i+1] = right[i] }
        }
        return StereoPCM(data: data, frames: frames)
    }
}

final class Capture {
    var tap: AudioObjectID = 0
    var device: AudioObjectID = 0
    var io: AudioDeviceIOProcID?
    var format = AudioStreamBasicDescription()
    var selected: [AudioObjectID] = []
    var tapUUID = UUID()
    let queue = DispatchQueue(label: "roomaudio.capture", qos: .userInteractive)
    var onAudio: ((Data, Double, Double, Int) -> Void)?
    var rate: Double { format.mSampleRate }

    private func description(processes: [AudioObjectID]) -> CATapDescription {
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = tapUUID
        description.name = "RoomAudio Spotify only"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        return description
    }
    func refreshSpotify() throws {
        let ids = try SpotifyProcesses.current()
        guard !ids.isEmpty else { throw audioError("Spotify is not available. Open the Spotify desktop app, play a track, then start sharing again. Other apps are never captured.") }
        guard ids != selected else { return }
        let description = description(processes: ids)
        var reference = Unmanaged.passUnretained(description).toOpaque()
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyDescription, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        try withExtendedLifetime(description) {
            try checked(AudioObjectSetPropertyData(tap, &address, 0, nil, UInt32(MemoryLayout<UnsafeMutableRawPointer>.size), &reference), "Update Spotify audio helpers")
        }
        selected = ids
    }
    func start() throws {
        do {
            selected = try SpotifyProcesses.current()
            guard !selected.isEmpty else { throw audioError("Open the Spotify desktop app and play a track before starting. Only Spotify can be shared; browser players and alerts are excluded.") }
            tapUUID = UUID()
            let description = description(processes: selected)
            try checked(AudioHardwareCreateProcessTap(description, &tap), "Create Spotify capture")
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try checked(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format), "Read Spotify capture format")
            let config: [String: Any] = [
                kAudioAggregateDeviceNameKey: "RoomAudio Spotify capture",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]
            ]
            try checked(AudioHardwareCreateAggregateDevice(config as CFDictionary, &device), "Create Spotify capture device")
            // A tap-only aggregate can default to a different rate from the tap. Set it
            // explicitly, then read the device's effective input format after configuration.
            var desiredRate = format.mSampleRate
            address.mSelector = kAudioDevicePropertyNominalSampleRate
            try checked(AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Double>.size), &desiredRate), "Match capture sample rate")
            var actualRate = 0.0
            size = UInt32(MemoryLayout<Double>.size)
            try checked(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &actualRate), "Read actual capture sample rate")
            address.mSelector = kAudioDevicePropertyStreams
            address.mScope = kAudioDevicePropertyScopeInput
            size = 0
            try checked(AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size), "Read capture input streams")
            var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
            guard streams.count == 1 else { throw audioError("The Spotify capture device must expose exactly one stereo input stream.") }
            try checked(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams), "Read capture stream")
            address.mSelector = kAudioStreamPropertyVirtualFormat
            address.mScope = kAudioObjectPropertyScopeGlobal
            size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try checked(AudioObjectGetPropertyData(streams[0], &address, 0, nil, &size, &format), "Read actual input sample format")
            guard format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32, format.mChannelsPerFrame == 2,
                  (8000...192000).contains(actualRate), abs(format.mSampleRate - actualRate) < 1 else {
                throw audioError("Unsupported Spotify input format. Choose a stereo output device, then restart sharing.")
            }
            format.mSampleRate = actualRate
            try checked(AudioDeviceCreateIOProcIDWithBlock(&io, device, queue) { [weak self] _, input, timestamp, _, _ in
                guard let self else { return }
                let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                guard let pcm = StereoPCM.copy(buffers) else { return }
                let time = timestamp.pointee
                let stamp = time.mFlags.contains(.hostTimeValid) ? AVAudioTime.seconds(forHostTime: time.mHostTime) : now()
                self.onAudio?(pcm.data, self.format.mSampleRate, stamp, pcm.frames)
            }, "Prepare Spotify capture")
            try checked(AudioDeviceStart(device, io), "Start Spotify capture")
        } catch { stop(); throw error }
    }
    func stop() {
        if device != 0 {
            if let io { AudioDeviceStop(device, io); AudioDeviceDestroyIOProcID(device, io) }
            AudioHardwareDestroyAggregateDevice(device)
        }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap) }
        io = nil; device = 0; tap = 0; selected = []
    }
    deinit { stop() }
}

struct PlaybackTimeline {
    var anchor: Double?
    var frames: Int64 = 0
    mutating func reset() { anchor = nil; frames = 0 }
    // Retain one continuous sample timeline. Timestamp jitter must never punch tiny
    // holes into every audio buffer. A genuine discontinuity needs a new anchor.
    mutating func append(target: Double, count: Int, rate: Double) -> Bool {
        var restart = anchor == nil
        if let anchor, abs(target - (anchor + Double(frames) / rate)) > 0.05 { restart = true }
        if restart { anchor = target; frames = 0 }
        frames += Int64(count)
        return restart
    }
}

final class Speaker {
    var engine: AVAudioEngine?
    var player: AVAudioPlayerNode?
    var speed: AVAudioUnitVarispeed?
    var rate: Double = 0
    var dropped = 0
    var rendered = 0
    var adjustment: Double = 0
    var timeline = PlaybackTimeline()
    var correction: Float = 1
    var lastCorrection = 0.0
    var nextSourceFrame: Int64?
    func prepare(rate: Double) throws {
        if self.rate != rate {
            stop()
            let engine = AVAudioEngine(), player = AVAudioPlayerNode(), speed = AVAudioUnitVarispeed()
            engine.attach(player); engine.attach(speed)
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
            engine.connect(player, to: speed, format: format)
            engine.connect(speed, to: engine.mainMixerNode, format: format)
            engine.prepare()
            try engine.start()
            self.engine = engine; self.player = player; self.speed = speed; self.rate = rate
        }
    }
    static func buffer(_ pcm: Data, rate: Double, frames: Int) -> AVAudioPCMBuffer? {
        guard frames > 0, frames <= 16384, pcm.count == frames * 8,
              rate.isFinite, (8000...192000).contains(rate),
              let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { bytes in
            for i in 0..<frames {
                let left = bytes.loadUnaligned(fromByteOffset: i * 8, as: Float.self)
                let right = bytes.loadUnaligned(fromByteOffset: i * 8 + 4, as: Float.self)
                channels[0][i] = left.isFinite ? left : 0
                channels[1][i] = right.isFinite ? right : 0
            }
        }
        return buffer
    }
    func enqueue(_ pcm: Data, rate: Double, at target: Double, frames: Int, sourceFrame: Int64? = nil) throws {
        guard let buffer = Self.buffer(pcm, rate: rate, frames: frames), target.isFinite else { return }
        try prepare(rate: rate)
        guard let engine, let player, let speed else { return }
        let current = now()
        let outputLatency = engine.outputNode.presentationLatency
        let scheduled = target + adjustment - outputLatency
        guard scheduled > current + 0.005, scheduled < current + 3 else { dropped += 1; return }
        if let sourceFrame {
            guard sourceFrame >= 0, sourceFrame <= Int64.max - Int64(frames) else { return }
            if let nextSourceFrame, sourceFrame != nextSourceFrame { timeline.reset() }
            nextSourceFrame = sourceFrame + Int64(frames)
        }
        let restart = timeline.append(target: scheduled, count: frames, rate: rate)
        if restart {
            player.stop()
            correction = 1; speed.rate = 1
            // Anchor the start once; subsequent buffers append sample-contiguously.
            player.scheduleBuffer(buffer, at: nil)
            player.play(at: AVAudioTime(hostTime: ticks(scheduled)))
        } else {
            // Slowly reconcile independent device clocks without per-buffer gaps,
            // overlaps or audible jumps in pitch. Limit adjustment to ±0.1 percent.
            if current - lastCorrection > 0.2,
               let node = player.lastRenderTime,
               let playTime = player.playerTime(forNodeTime: node), playTime.sampleTime > 0 {
                let queuedFrames = Double(timeline.frames - Int64(frames))
                let predicted = AVAudioTime.seconds(forHostTime: node.hostTime) + (queuedFrames - Double(playTime.sampleTime)) / rate / Double(correction)
                let error = predicted - scheduled
                let requested = Float(min(1.001, max(0.999, 1 + error * 0.02)))
                correction += (requested - correction) * 0.05
                speed.rate = correction
                lastCorrection = current
            }
            player.scheduleBuffer(buffer, at: nil)
        }
        rendered += 1
    }
    func stop() {
        player?.stop(); engine?.stop()
        player = nil; speed = nil; engine = nil; rate = 0
        timeline.reset(); correction = 1; lastCorrection = 0; nextSourceFrame = nil
    }
}
