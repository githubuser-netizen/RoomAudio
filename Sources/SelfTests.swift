import Foundation
import Network

func runSelfTests() {
    do { try testAudioEngine() } catch { fatalError("Audio regression test failed: \(error)") }
    var clock = ClockSync()
    // Sender clock is 100 seconds ahead; symmetric 10 ms each-way transport.
    clock.add(t1: 10, t2: 110.01, t3: 110.012, t4: 10.022)
    precondition(abs(clock.offset - 100) < 0.000001)
    precondition(abs(clock.uncertainty - 10) < 0.000001)
    // A worse asymmetric sample must not replace the best round trip.
    clock.add(t1: 11, t2: 111.1, t3: 111.102, t4: 11.122)
    precondition(abs(clock.offset - 100) < 0.000001)
    let count = clock.samples.count
    clock.add(t1: .nan, t2: 1, t3: 2, t4: 3)
    precondition(clock.samples.count == count)
    for i in 0..<100 { clock.add(t1: Double(i), t2: Double(i)+100.01, t3: Double(i)+100.012, t4: Double(i)+0.022) }
    precondition(clock.samples.count == 32)
    let data = Data((0..<8192).map { UInt8($0 % 251) })
    let packet = Packet(kind: "audio", at: 123.5, rate: 48000, frames: 1024, pcm: data)
    let decoded = try! JSONDecoder().decode(Packet.self, from: JSONEncoder().encode(packet))
    precondition(decoded.pcm == data && decoded.at == 123.5)

    let queue = DispatchQueue(label: "roomaudio.test")
    let complete = DispatchSemaphore(value: 0)
    let listener = try! NWListener(using: .tcp, on: .any)
    var server: Wire?, client: Wire?
    listener.newConnectionHandler = { connection in
        let wire = Wire(connection, queue: queue)
        server = wire
        wire.onPacket = { packet in
            precondition(packet.kind == "hello" && packet.token == "123456")
            wire.send(Packet(kind: "welcome"))
            wire.send(Packet(kind: "audio", at: 123.5, rate: 48000, frames: 1024, pcm: data))
        }
        wire.start()
    }
    listener.stateUpdateHandler = { state in
        if case .ready = state, let port = listener.port {
            let wire = Wire(NWConnection(host: "127.0.0.1", port: port, using: .tcp), queue: queue)
            client = wire
            wire.onReady = { wire.send(Packet(kind: "hello", token: "123456")) }
            wire.onPacket = { packet in
                if packet.kind == "audio" {
                    precondition(packet.pcm == data && packet.frames == 1024)
                    complete.signal()
                }
            }
            wire.start()
        }
    }
    listener.start(queue: queue)
    precondition(complete.wait(timeout: .now() + 5) == .success, "Loopback transport timed out")
    queue.sync { client?.close(); server?.close(); listener.cancel() }
    print("PASS: clock offset, jitter selection, invalid samples, bounded clock history, PCM round trip, live TCP pairing and audio transport.")
}
