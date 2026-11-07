# RoomAudio for iPhone and iPad

A native receiver for Spotify audio shared by a Mac or Windows PC. This is a buildable iOS app project, not an App Store/TestFlight release or a ready-to-install IPA.

## What it can do

- Connect using the computer's Wi-Fi address and room code.
- Receive the same framed PCM protocol used by Mac and Windows.
- Use the shared Apple playback engine, including continuous buffer scheduling, sample-rate handling, output latency compensation and room timing adjustment.
- Configure the audio session for playback and declare the audio background mode so playback can continue with the screen locked. Real-device locked-screen/network behavior still needs testing.
- Stop cleanly for audio interruptions and disconnected output devices; reconnect manually afterward.

The iPhone is a **receiver only**. There is no public Core Audio process-tap equivalent for selectively capturing another iOS app's Spotify audio and muting its original output. ReplayKit is not used as a substitute for that behavior. Spotify stays on the main computer, so its other app sounds are not transmitted.

## Build/run

Requires Xcode 26 or later and iOS/iPadOS 17 or later.

1. Clone/download the **whole repository**. The project references shared source in `../Sources/Audio.swift` and `../Sources/Network.swift`; do not move the iOS folder out of the repository.
2. Open `RoomAudioiOS.xcodeproj` in Xcode and choose the **RoomAudioiOS** scheme.
3. For a simulator, build/run directly.
4. For a real iPhone, choose your own signing team in **Signing & Capabilities**, use a unique bundle identifier if required, connect the phone and run. Apple signing and any device setup are user-managed. For distribution, archive using your Apple Developer account and follow Apple's TestFlight/App Store workflow.
5. Allow Local Network access. Enter your computer's address and room code, then Connect.

You cannot AirDrop the Mac app or an unsigned iOS build to install it on an iPhone. No Apple account or signing credentials are stored in this project.

Command-line simulator build:

```sh
xcodebuild -project iOS/RoomAudioiOS.xcodeproj -scheme RoomAudioiOS \
  -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

## Verification and limits

The simulator target compiles successfully. The shared Apple engine passes the Mac's offline pitch/continuity tests. The app has **not** been run on an iPhone, and real-device synchronization, background playback and local-network permissions remain unverified.

Use the same trusted private network as your main computer. Audio is not encrypted. Built-in or wired output is preferable; Bluetooth and AirPlay can add latency beyond the room timing adjustment. Clock estimates do not measure acoustic sync.

Apple references: [background audio playback](https://developer.apple.com/documentation/avfoundation/configuring-your-app-for-media-playback), [ReplayKit scope](https://developer.apple.com/documentation/replaykit).
