import SwiftUI

final class PhoneModel: ObservableObject {
    @Published var address = ""
    @Published var code = ""
    @Published var connected = false
    @Published var message = "Start sharing Spotify on your Mac or Windows PC, then connect here."
    @Published var timing = 0.0
    let receiver = IPhoneReceiver()
    init() {
        receiver.onStatus = { [weak self] in self?.message = $0 }
        receiver.onStopped = { [weak self] in self?.connected = false }
    }
    func connect() {
        connected = true
        receiver.adjust(timing)
        receiver.connect(address: address.trimmingCharacters(in: .whitespacesAndNewlines), code: code)
    }
    func stop() { receiver.stop(); connected = false; message = "Stopped." }
}
@main
struct RoomAudioiOSApp: App {
    @StateObject var model = PhoneModel()
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                Form {
                    Section {
                        TextField("Main player address", text: $model.address)
                            .keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(model.connected)
                        TextField("Six-digit room code", text: $model.code)
                            .keyboardType(.numberPad).disabled(model.connected)
                    } header: { Text("Connect to your computer") } footer: {
                        Text("Use the same Wi-Fi. Only Spotify from the computer is shared; its WhatsApp alerts stay there.")
                    }
                    Section {
                        if model.connected { Button("Disconnect", role: .destructive) { model.stop() } }
                        else {
                            Button("Connect") { model.connect() }
                                .disabled(model.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.code.count != 6)
                        }
                        Text(model.message).font(.callout).foregroundStyle(.secondary)
                    }
                    Section {
                        HStack { Text("Room timing"); Spacer(); Text(String(format: "%+.0f ms", model.timing)).monospacedDigit().foregroundStyle(.secondary) }
                        Slider(value: $model.timing, in: -200...200, step: 1).accessibilityLabel("Room timing in milliseconds")
                            .onChange(of: model.timing) { _, value in model.receiver.adjust(value) }
                    } footer: { Text("If this room is late, move left. If early, move right. Bluetooth and AirPlay add latency; built-in or wired speakers work best.") }
                    Section {
                        Text("This iPhone receives audio. Spotify stays on your computer. Playback is configured to continue when the screen locks.")
                        Text("Use a trusted private network. Audio is not encrypted. Clock estimates don’t measure acoustic speaker sync.")
                            .foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("RoomAudio")
            }
            .tint(.teal)
        }
    }
}
