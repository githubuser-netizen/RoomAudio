import Foundation
import AVFoundation
import Network

final class IPhoneReceiver {
    let queue = DispatchQueue(label: "roomaudio.ios.network", qos: .userInteractive)
    let audioQueue = DispatchQueue(label: "roomaudio.ios.audio", qos: .userInteractive)
    let slots = DispatchSemaphore(value: 64)
    let speaker = Speaker()
    var wire: Wire?
    var clock = ClockSync()
    var outstanding: Set<Double> = []
    var timer: DispatchSourceTimer?
    var generation: UInt64 = 0
    var active = false
    var ticks = 0
    var onStatus: ((String) -> Void)?
    var onStopped: (() -> Void)?
    var interruption: NSObjectProtocol?
    var routeChange: NSObjectProtocol?
    init() {
        interruption = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            guard let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt, type == AVAudioSession.InterruptionType.began.rawValue else { return }
            self?.queue.async { self?.fail("Playback interrupted. Tap Connect to resume after the call or interruption.") }
        }
        routeChange = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] note in
            guard let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            self?.queue.async { self?.fail("Audio output disconnected. Check your speakers, then reconnect.") }
        }
    }
    func status(_ message: String) { DispatchQueue.main.async { [weak self] in self?.onStatus?(message) } }
    func connect(address: String, code: String) {
        queue.async { [self] in
            stopInternal(); active = true
            let sessionGeneration = generation
            do {
                let audio = AVAudioSession.sharedInstance()
                try audio.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
                try audio.setActive(true)
            } catch { fail(error.localizedDescription); return }
            let wire = Wire(NWConnection(host: NWEndpoint.Host(address), port: 48921, using: .tcp), queue: queue)
            self.wire = wire
            wire.onReady = { [weak wire, weak self] in wire?.send(Packet(kind: "hello", token: code)); self?.status("Checking the room code…") }
            wire.onPacket = { [weak self] packet in self?.receive(packet) }
            wire.onClose = { [weak self] in self?.fail("Connection closed. Check the address and room code, then reconnect.") }
            wire.start(); status("Connecting to your computer…")
            queue.asyncAfter(deadline: .now() + 12) { [weak self] in
                guard let self, self.active, self.generation == sessionGeneration, self.timer == nil else { return }
                self.fail("Couldn’t connect. Use the same Wi-Fi, allow Local Network access, and check your computer’s firewall.")
            }
        }
    }
    func receive(_ packet: Packet) {
        guard active else { return }
        switch packet.kind {
        case "welcome":
            status("Aligning clocks…")
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(200))
            timer.setEventHandler { [weak self] in
                guard let self, self.active else { return }
                self.ticks += 1
                if self.ticks < 15 || self.ticks % 5 == 0 {
                    let stamp = now(); self.outstanding = self.outstanding.filter { stamp - $0 < 5 }; self.outstanding.insert(stamp)
                    self.wire?.send(Packet(kind: "ping", t1: stamp))
                }
                if self.ticks % 5 == 0, self.clock.samples.count >= 5 {
                    let late = self.audioQueue.sync { self.speaker.dropped }
                    self.status("Connected · clock estimate ±\(String(format: "%.1f", self.clock.uncertainty)) ms · \(late) late buffers")
                }
            }
            self.timer?.cancel(); self.timer = timer; timer.resume()
        case "pong":
            if let t1 = packet.t1, let t2 = packet.t2, let t3 = packet.t3, outstanding.remove(t1) != nil { clock.add(t1: t1, t2: t2, t3: t3, t4: now()) }
        case "audio":
            guard clock.samples.count >= 5, let data = packet.pcm, let at = packet.at, at.isFinite,
                  let rate = packet.rate, let frames = packet.frames else { return }
            guard slots.wait(timeout: .now()) == .success else { fail("Audio couldn’t keep up. Reconnect on a stronger Wi-Fi connection."); return }
            let target = at - clock.offset, sessionGeneration = generation
            audioQueue.async { [self] in
                defer { slots.signal() }
                do { try speaker.enqueue(data, rate: rate, at: target, frames: frames, sourceFrame: packet.position) }
                catch { queue.async { [weak self] in
                    guard let self, self.active, self.generation == sessionGeneration else { return }
                    self.fail(error.localizedDescription)
                } }
            }
        default: break
        }
    }
    func adjust(_ milliseconds: Double) { audioQueue.async { self.speaker.adjustment = milliseconds / 1000 } }
    func stop() { queue.sync { stopInternal() } }
    func fail(_ message: String) {
        guard active else { return }
        stopInternal(); status(message)
        DispatchQueue.main.async { [weak self] in self?.onStopped?() }
    }
    private func stopInternal() {
        active = false; generation &+= 1
        wire?.onClose = nil; wire?.close(); wire = nil
        timer?.cancel(); timer = nil; ticks = 0
        audioQueue.sync { speaker.stop(); speaker.dropped = 0 }
        clock = ClockSync(); outstanding.removeAll()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    deinit {
        if let interruption { NotificationCenter.default.removeObserver(interruption) }
        if let routeChange { NotificationCenter.default.removeObserver(routeChange) }
    }
}
