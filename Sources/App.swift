import SwiftUI
import AppKit
import Darwin

func localAddresses() -> String {
    var pointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&pointer) == 0, let first = pointer else { return "" }
    defer { freeifaddrs(pointer) }
    var addresses: [String] = []
    var item: UnsafeMutablePointer<ifaddrs>? = first
    while let current = item {
        defer { item = current.pointee.ifa_next }
        let entry = current.pointee
        guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET), String(cString: entry.ifa_name).hasPrefix("en") else { continue }
        var result = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(address, socklen_t(address.pointee.sa_len), &result, socklen_t(result.count), nil, 0, NI_NUMERICHOST) == 0 { addresses.append(String(cString: result)) }
    }
    return addresses.joined(separator: " or ")
}

final class Model: ObservableObject {
    @Published var role = 0
    @Published var address = ""
    @Published var roomCode = ""
    @Published var busy = false
    @Published var status = "Ready. Open RoomAudio on both Macs to begin."
    @Published var adjustment = 0.0
    let hostCode = String(Int.random(in: 100000...999999))
    let addresses = localAddresses()
    let session = Session()
    init() {
        session.onStatus = { [weak self] in self?.status = $0 }
        session.onStopped = { [weak self] in self?.busy = false }
    }
    func start() {
        busy = true
        session.adjust(adjustment)
        if role == 0 { session.startHost(code: hostCode) }
        else { session.join(address: address.trimmingCharacters(in: .whitespacesAndNewlines), code: roomCode.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
    func stop() { session.stop(); busy = false; status = "Stopped. Normal audio output is restored." }
}

struct RoomView: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "hifispeaker.2").font(.system(size: 34)).foregroundStyle(Color.accentColor).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Spotify in both rooms").font(.system(size: 25, weight: .semibold))
                    Text("MacBook Pro plays. Mac mini follows.").foregroundStyle(.secondary)
                }
            }
            Picker("This Mac", selection: $model.role) {
                Text("Main player · MacBook Pro").tag(0)
                Text("Receiver · Mac mini").tag(1)
            }.pickerStyle(.segmented).disabled(model.busy)
            if model.role == 0 {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Connect the Mac mini").font(.headline)
                    Text("Open RoomAudio on the mini, choose Receiver, and enter these details.").fixedSize(horizontal: false, vertical: true)
                    LabeledContent("Main player address") { Text(model.addresses.isEmpty ? "No Wi-Fi address found" : model.addresses).textSelection(.enabled) }
                    LabeledContent("Room code") { Text(model.hostCode).font(.system(.title2, design: .monospaced)).textSelection(.enabled) }
                    Text("Open Spotify and play a track before starting. Only the Spotify desktop app is shared. WhatsApp alerts and other sounds stay here.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Join the main player").font(.headline)
                    TextField("Main player address", text: $model.address, prompt: Text("e.g. 192.168.1.20")).textFieldStyle(.roundedBorder).disabled(model.busy)
                    TextField("Room code", text: $model.roomCode, prompt: Text("Six-digit code shown on the MacBook Pro")).textFieldStyle(.roundedBorder).disabled(model.busy)
                    Text("Keep Spotify playing only on the MacBook Pro. Use the same Wi-Fi on both Macs.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("Room timing").font(.headline)
                    Spacer()
                    Text(String(format: "%+.0f ms", model.adjustment)).monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $model.adjustment, in: -200...200, step: 1) { Text("Room timing in milliseconds") }
                    .onChange(of: model.adjustment) { _, value in model.session.adjust(value) }
                Text("If this room sounds late, move left. If it sounds early, move right. Start with built-in or wired speakers.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .center, spacing: 16) {
                if model.busy {
                    Button("Stop", action: model.stop).keyboardShortcut(.cancelAction)
                } else {
                    Button(model.role == 0 ? "Start sharing" : "Connect", action: model.start)
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(model.role == 1 && (model.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.roomCode.count != 6))
                }
                Text(model.status).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }.frame(minHeight: 42)
            Text("Both rooms use an 800 ms buffer. Clock estimates do not measure speaker sync; adjust timing by ear. Changing output devices requires Stop, then Start.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(28).frame(width: 580).tint(.teal)
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: Model?
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { model?.session.stop() }
}
@main
struct RoomAudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var model = Model()
    init() {
        if CommandLine.arguments.contains("--self-test") { runSelfTests(); exit(0) }
    }
    var body: some Scene {
        Window("RoomAudio", id: "main") {
            RoomView(model: model).onAppear { delegate.model = model }
        }.windowResizability(.contentSize)
    }
}
