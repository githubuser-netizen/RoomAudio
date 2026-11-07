// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "RoomAudio", platforms: [.macOS("14.2")], products: [.executable(name: "RoomAudio", targets: ["RoomAudio"])], targets: [.executableTarget(name: "RoomAudio", path: "Sources", swiftSettings: [.swiftLanguageMode(.v5)])])
