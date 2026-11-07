import Foundation
import Network

struct Packet: Codable {
    var kind: String
    var token: String? = nil
    var t1: Double? = nil
    var t2: Double? = nil
    var t3: Double? = nil
    var at: Double? = nil
    var rate: Double? = nil
    var frames: Int? = nil
    var pcm: Data? = nil
    var position: Int64? = nil
}

final class Wire {
    let connection: NWConnection
    let queue: DispatchQueue
    var input = Data()
    var pending = 0
    var closed = false
    var onPacket: ((Packet) -> Void)?
    var onClose: (() -> Void)?
    var onReady: (() -> Void)?
    init(_ connection: NWConnection, queue: DispatchQueue) { self.connection = connection; self.queue = queue }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.onReady?(); self.read()
            case .failed, .cancelled: self.close()
            default: break
            }
        }
        connection.start(queue: queue)
    }
    func send(_ packet: Packet) {
        guard !closed, pending < 32, let payload = try? JSONEncoder().encode(packet), payload.count < 256_000 else { close(); return }
        var size = UInt32(payload.count).bigEndian
        var bytes = Data(bytes: &size, count: 4)
        bytes.append(payload)
        pending += 1
        connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.pending -= 1
            if error != nil { self.close() }
        })
    }
    func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data { self.input.append(data) }
            while self.input.count >= 4 {
                let count = Int(self.input.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) })
                guard count > 0, count < 256_000 else { self.close(); return }
                guard self.input.count >= count + 4 else { break }
                let payload = self.input.subdata(in: 4..<(4 + count))
                self.input.removeSubrange(0..<(4 + count))
                guard let packet = try? JSONDecoder().decode(Packet.self, from: payload) else { self.close(); return }
                self.onPacket?(packet)
                if self.closed { return }
            }
            if complete || error != nil { self.close() } else { self.read() }
        }
    }
    func close() {
        guard !closed else { return }
        closed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose?()
    }
}

struct ClockSample { let offset: Double; let rtt: Double }
struct ClockSync {
    var samples: [ClockSample] = []
    var offset: Double { samples.min(by: { $0.rtt < $1.rtt })?.offset ?? 0 }
    var uncertainty: Double { (samples.min(by: { $0.rtt < $1.rtt })?.rtt ?? 0) * 500 }
    mutating func add(t1: Double, t2: Double, t3: Double, t4: Double) {
        let rtt = (t4-t1) - (t3-t2)
        guard [t1,t2,t3,t4,rtt].allSatisfy({ $0.isFinite }), rtt >= 0, rtt < 0.5 else { return }
        samples.append(ClockSample(offset: ((t2-t1)+(t3-t4))/2, rtt: rtt))
        if samples.count > 32 { samples.removeFirst() }
    }
}

final class Session {
    let queue = DispatchQueue(label: "roomaudio.session", qos: .userInteractive)
    let audioQueue = DispatchQueue(label: "roomaudio.playback", qos: .userInteractive)
    let localSlots = DispatchSemaphore(value: 64)
    var generation: UInt64 = 0
    let capture = Capture()
    let speaker = Speaker()
    let slots = DispatchSemaphore(value: 12)
    var listener: NWListener?
    var peers: [ObjectIdentifier: Wire] = [:]
    var paired: Set<ObjectIdentifier> = []
    var guest: Wire?
    var timer: DispatchSourceTimer?
    var clock = ClockSync()
    var outstanding: Set<Double> = []
    var code = ""
    var activity: NSObjectProtocol?
    var active = false
    var host = false
    var lastAudio = 0.0
    var clockTicks = 0
    var onStatus: ((String) -> Void)?
    var onStopped: (() -> Void)?
    func status(_ message: String) { DispatchQueue.main.async { [weak self] in self?.onStatus?(message) } }
    func startHost(code: String) {
        queue.async { [self] in
            stopInternal()
            self.code = code; host = true; active = true
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Sharing audio across rooms")
            do {
                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = true
                let listener = try NWListener(using: parameters, on: 48921)
                self.listener = listener
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.stateUpdateHandler = { [weak self] state in
                    if case .failed(let error) = state { self?.fail("Cannot listen: \(error.localizedDescription)") }
                }
                listener.start(queue: queue)
                let generation = self.generation
                var position: Int64 = 0
                capture.onAudio = { [weak self] data, rate, stamp, frames in
                    guard let self else { return }
                    let framePosition = position
                    position += Int64(frames)
                    let target = stamp + 0.8
                    self.play(data, rate: rate, target: target, frames: frames, position: framePosition, generation: generation)
                    // Local playback never waits for JSON encoding or a slow receiver.
                    guard self.slots.wait(timeout: .now()) == .success else { return }
                    self.queue.async {
                        defer { self.slots.signal() }
                        guard self.active, self.host, self.generation == generation else { return }
                        let packet = Packet(kind: "audio", at: target, rate: rate, frames: frames, pcm: data, position: framePosition)
                        for id in self.paired { self.peers[id]?.send(packet) }
                        self.lastAudio = now()
                    }
                }
                try audioQueue.sync { try speaker.prepare(rate: 48000) }
                try capture.start()
                makeTimer()
                status("Sharing Spotify only. Alerts stay on this Mac. Waiting for the Mac mini.")
            } catch { fail(error.localizedDescription) }
        }
    }
    func accept(_ connection: NWConnection) {
        guard peers.count < 4 else { connection.cancel(); return }
        let wire = Wire(connection, queue: queue), id = ObjectIdentifier(connection)
        peers[id] = wire
        wire.onPacket = { [weak self, weak wire] packet in
            guard let self, let wire else { return }
            let received = now()
            if !self.paired.contains(id) {
                guard packet.kind == "hello", packet.token == self.code else { wire.close(); return }
                self.paired.insert(id)
                wire.send(Packet(kind: "welcome"))
            } else if packet.kind == "ping", let t1 = packet.t1, t1.isFinite {
                wire.send(Packet(kind: "pong", t1: t1, t2: received, t3: now()))
            }
        }
        wire.onClose = { [weak self] in self?.peers.removeValue(forKey: id); self?.paired.remove(id) }
        wire.start()
        queue.asyncAfter(deadline: .now() + 10) { [weak self, weak wire] in
            if self?.paired.contains(id) != true { wire?.close() }
        }
    }
    func join(address: String, code: String) {
        queue.async { [self] in
            stopInternal(); active = true; host = false; clock = ClockSync()
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Receiving audio across rooms")
            let wire = Wire(NWConnection(host: NWEndpoint.Host(address), port: 48921, using: .tcp), queue: queue)
            guest = wire
            status("Connecting to the MacBook Pro…")
            wire.onReady = { [weak self, weak wire] in
                wire?.send(Packet(kind: "hello", token: code))
                self?.status("Checking the room code…")
            }
            wire.onPacket = { [weak self] packet in self?.receive(packet) }
            wire.onClose = { [weak self] in self?.fail("Connection closed. Check the address and room code, then stop and connect again.") }
            wire.start()
            queue.asyncAfter(deadline: .now() + 12) { [weak self] in
                guard let self, self.active, self.timer == nil else { return }
                self.fail("Couldn’t connect. Check both Macs are on the same Wi-Fi and allow RoomAudio through the macOS firewall.")
            }
        }
    }
    func receive(_ packet: Packet) {
        guard active else { return }
        switch packet.kind {
        case "welcome": status("Aligning both Macs’ clocks…"); makeTimer()
        case "pong":
            if let t1 = packet.t1, let t2 = packet.t2, let t3 = packet.t3, outstanding.remove(t1) != nil {
                clock.add(t1: t1, t2: t2, t3: t3, t4: now())
            }
        case "audio":
            guard clock.samples.count >= 5,
                  let data = packet.pcm, let at = packet.at, at.isFinite,
                  let rate = packet.rate, let frames = packet.frames else { return }
            play(data, rate: rate, target: at - clock.offset, frames: frames, position: packet.position, generation: generation)
            lastAudio = now()
        default: break
        }
    }
    func play(_ data: Data, rate: Double, target: Double, frames: Int, position: Int64?, generation: UInt64) {
        guard localSlots.wait(timeout: .now()) == .success else {
            queue.async { [weak self] in
                guard let self, self.active, self.generation == generation else { return }
                self.fail("Audio playback couldn’t keep up. Stop other heavy tasks and restart sharing.")
            }
            return
        }
        audioQueue.async { [self] in
            defer { localSlots.signal() }
            do { try speaker.enqueue(data, rate: rate, at: target, frames: frames, sourceFrame: position) }
            catch {
                queue.async { [weak self] in
                    guard let self, self.active, self.generation == generation else { return }
                    self.fail(error.localizedDescription)
                }
            }
        }
    }
    func makeTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 0.2)
        timer.setEventHandler { [weak self] in
            guard let self, self.active else { return }
            self.clockTicks += 1
            if !self.host, self.clockTicks < 15 || self.clockTicks % 5 == 0 {
                let stamp = now()
                self.outstanding = self.outstanding.filter { stamp - $0 < 5 }
                self.outstanding.insert(stamp)
                self.guest?.send(Packet(kind: "ping", t1: stamp))
            }
            if self.clockTicks % 5 == 0 {
                let dropped = self.audioQueue.sync { self.speaker.dropped }
                if self.host {
                    do { try self.capture.refreshSpotify() }
                    catch { self.fail(error.localizedDescription); return }
                    self.status("Spotify only · \(Int(self.capture.rate)) Hz · \(self.paired.count) receiver(s) · \(dropped) late buffers skipped")
                } else if self.clock.samples.count >= 5 {
                    let playing = now() - self.lastAudio < 2
                    self.status("\(playing ? "Receiving audio" : "Connected · waiting for audio") · clock estimate ±\(String(format: "%.1f", self.clock.uncertainty)) ms · \(dropped) late buffers skipped")
                }
            }
        }
        self.timer = timer; timer.resume()
    }
    func adjust(_ milliseconds: Double) { audioQueue.async { self.speaker.adjustment = milliseconds / 1000 } }
    func fail(_ message: String) { stopInternal(); status(message); DispatchQueue.main.async { [weak self] in self?.onStopped?() } }
    func stop() { queue.sync { stopInternal() } }
    private func stopInternal() {
        active = false
        generation &+= 1
        if let activity { ProcessInfo.processInfo.endActivity(activity) }; activity = nil
        capture.stop(); capture.onAudio = nil
        audioQueue.sync { speaker.stop(); speaker.dropped = 0 }
        timer?.cancel(); timer = nil; clockTicks = 0; lastAudio = 0
        listener?.stateUpdateHandler = nil; listener?.cancel(); listener = nil
        guest?.onClose = nil; guest?.close(); guest = nil
        let all = Array(peers.values); peers.removeAll(); paired.removeAll()
        for wire in all { wire.onClose = nil; wire.close() }
        clock = ClockSync(); outstanding.removeAll()
    }
}
