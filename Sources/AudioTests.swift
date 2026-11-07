import Foundation
import AVFoundation
import CoreAudio

func testAudioEngine() throws {
    precondition(SpotifyProcesses.includes(bundle: "com.spotify.client"))
    precondition(SpotifyProcesses.includes(bundle: "com.spotify.client.helper"))
    for bundle in ["net.whatsapp.WhatsApp", "com.apple.Safari", "com.spotify.clientevil", "local.roomaudio.app", ""] {
        precondition(!SpotifyProcesses.includes(bundle: bundle), "Non-Spotify process admitted: \(bundle)")
    }
    let frames = 512
    var left = (0..<frames).map { Float(sin(Double($0) * 0.17) * 0.3) }
    var right = (0..<frames).map { Float(cos(Double($0) * 0.31) * 0.2) }
    var interleaved = [Float](repeating: 0, count: frames * 2)
    for i in 0..<frames { interleaved[2*i] = left[i]; interleaved[2*i+1] = right[i] }
    let expected = interleaved.withUnsafeBytes { Data($0) }
    let list = AudioBufferList.allocate(maximumBuffers: 2)
    defer { list.unsafeMutablePointer.deallocate() }
    left.withUnsafeMutableBufferPointer { l in
        right.withUnsafeMutableBufferPointer { r in
            list.unsafeMutablePointer.pointee.mNumberBuffers = 2
            list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: l.baseAddress)
            list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: r.baseAddress)
            let pcm = StereoPCM.copy(list)!
            precondition(pcm.frames == frames && pcm.data == expected, "Planar PCM must preserve both channels and all frames")
            list[1].mDataByteSize -= 4
            precondition(StereoPCM.copy(list) == nil, "Mismatched channel lengths must be rejected")
        }
    }
    interleaved.withUnsafeMutableBufferPointer { samples in
        list.unsafeMutablePointer.pointee.mNumberBuffers = 1
        list[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: samples.baseAddress)
        let pcm = StereoPCM.copy(list)!
        precondition(pcm.frames == frames && pcm.data == expected, "Interleaved PCM must preserve pitch and channel order")
    }
    for rate in [44100.0, 48000.0] {
        var timeline = PlaybackTimeline()
        var restarts = 0
        for i in 0..<10000 {
            let jitter = i % 2 == 0 ? 0.0004 : -0.0004
            if timeline.append(target: 10 + Double(i * frames) / rate + jitter, count: frames, rate: rate) { restarts += 1 }
        }
        precondition(restarts == 1, "Callback jitter must not create buffer gaps")
        precondition(timeline.frames == Int64(10000 * frames))
        precondition(timeline.append(target: 20 + Double(10000 * frames) / rate, count: frames, rate: rate), "Real discontinuities must reanchor")
        try testOfflinePlayback(sourceRate: rate)
    }
    print("PASS: Spotify-only selection; planar/interleaved PCM pitch and channel integrity; malformed buffers; continuous jitter-tolerant timeline; offline 44.1/48 kHz sine rendering with rate conversion.")
}

private func testOfflinePlayback(sourceRate: Double) throws {
    let engine = AVAudioEngine(), player = AVAudioPlayerNode(), speed = AVAudioUnitVarispeed()
    let format = AVAudioFormat(standardFormatWithSampleRate: sourceRate, channels: 2)!
    let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    engine.attach(player); engine.attach(speed)
    engine.connect(player, to: speed, format: format)
    engine.connect(speed, to: engine.mainMixerNode, format: format)
    try engine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: 1024)
    let count = Int(sourceRate * 2)
    for start in stride(from: 0, to: count, by: 512) {
        let frames = min(512, count - start)
        var stereo = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            stereo[2*i] = Float(0.3 * sin(2 * .pi * 440 * Double(start + i) / sourceRate))
            stereo[2*i+1] = Float(0.2 * sin(2 * .pi * 880 * Double(start + i) / sourceRate))
        }
        let data = stereo.withUnsafeBytes { Data($0) }
        player.scheduleBuffer(Speaker.buffer(data, rate: sourceRate, frames: frames)!, at: nil)
    }
    try engine.start(); player.play()
    defer { player.stop(); engine.stop() }
    let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 1024)!
    var left: [Float] = [], right: [Float] = []
    var attempts = 0
    while left.count < 96000, attempts < 200 {
        attempts += 1
        let status = try engine.renderOffline(AVAudioFrameCount(min(1024, 96000 - left.count)), to: output)
        if status == .success {
            left.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
            right.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![1], count: Int(output.frameLength)))
        } else if status == .error { throw audioError("Offline rendering failed") }
    }
    precondition(left.count == 96000)
    // Ignore initial converter priming and the tail, then check signal continuity,
    // level and frequency rather than merely checking the buffer count.
    for (samples, frequency, amplitude) in [(left, 440.0, 0.3), (right, 880.0, 0.2)] {
        let signal = Array(samples[1024..<94000])
        precondition(signal.allSatisfy { $0.isFinite })
        let rms = sqrt(signal.reduce(0.0) { $0 + Double($1 * $1) } / Double(signal.count))
        precondition(abs(rms - amplitude / sqrt(2)) < 0.01, "Audio level changed unexpectedly")
        var crossings = 0, longestSilence = 0, silence = 0
        var maxJump: Float = 0
        for i in 1..<signal.count {
            if signal[i-1] <= 0 && signal[i] > 0 { crossings += 1 }
            maxJump = max(maxJump, abs(signal[i] - signal[i-1]))
            silence = abs(signal[i]) < 0.000001 ? silence + 1 : 0
            longestSilence = max(longestSilence, silence)
        }
        let measured = Double(crossings) / (Double(signal.count) / 48000)
        precondition(abs(measured - frequency) < 1, "Pitch changed: \(measured) Hz instead of \(frequency)")
        precondition(longestSilence <= 2, "Audio dropped out between buffers")
        precondition(maxJump < 0.04, "Discontinuity would produce a click")
    }
}
