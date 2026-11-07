# RoomAudio

An experimental native Mac app: play Spotify on the MacBook Pro and send the same Spotify audio to a Mac mini on the same home network. Both Macs use timestamped, delayed playback. No Spotify credentials, virtual audio driver, cloud server, or extra Spotify player is used.

## Requirements

- Two Apple silicon Macs running macOS 14.2 or later on the same private network.
- Spotify desktop app on the main Mac.
- To build: Apple Command Line Tools with Swift 6 and a recent macOS SDK.

## Build

```sh
git clone https://github.com/githubuser-netizen/RoomAudio.git
cd RoomAudio
./build.command
```

This creates `dist/RoomAudio.app` and `dist/RoomAudio.zip`. Copy the same app to both Macs.

## Start listening

1. Open `dist/RoomAudio.app` on the MacBook Pro.
2. AirDrop `dist/RoomAudio.zip` to the Mac mini, unzip it, and open RoomAudio there. Both Macs need macOS 14.2 or later. The app requires Apple silicon (M-series) on both Macs.
3. On the MacBook Pro, select **Main player** and press **Start sharing** (with the Spotify desktop app already open and playing). Allow system audio recording and local network access if macOS asks. If you enabled permission in Settings, quit and reopen the app.
4. On the mini, select **Receiver**. Enter the address and six-digit room code shown on the MacBook Pro, then press **Connect**. Allow local network access and firewall connections when asked.
5. Play Spotify on the MacBook Pro. Keep Spotify stopped on the mini. Both Macs play after the buffer fills and the clocks align (roughly three seconds after connecting).
6. If you hear an echo between rooms, adjust **Room timing** on the mini: left if the mini is late; right if it is early. Changes take effect on newly scheduled audio, so allow about a second to settle.

**Stop** restores the main Mac’s normal sound output. Quitting also releases capture and playback. The app prevents idle system sleep while sharing/receiving; closing a laptop lid or manually sleeping a Mac still interrupts playback.

Use the built-in speakers or wired speakers first. Bluetooth and wireless output devices add variable latency. Changing output devices or recovering from sleep requires Stop and Start/Connect. If more than one main-player address is shown, use the address on the shared Wi-Fi network.

## Scope and limits

- Shares **only the Spotify desktop app and audio helpers with Spotify bundle identifiers**. WhatsApp alerts, browser sounds and system notifications remain local to the main Mac. It never falls back to global capture. If Spotify closes, sharing stops; reopen Spotify and restart.
- Uses an 800 ms buffer on both Macs, a four-timestamp clock offset estimate, periodic clock checks, output latency compensation, and a ±200 ms manual adjustment.
- Clock uncertainty shown in the app is a network estimate, **not a measurement of acoustic speaker synchronization**. Hardware clock drift, output latency reporting, Wi-Fi congestion, and room acoustics can still cause audible misalignment. Cross-Mac acoustic sync requires testing on the actual pair; it is not verified by the build or loopback tests.
- Sends uncompressed stereo float PCM over TCP. At 48 kHz the JSON/base64 transport uses about 0.55 MB/s. Late buffers are discarded rather than played late; sustained congestion disconnects a backlogged receiver. Reconnect manually.
- Audio is paired using a fresh random room code but the transport is **not encrypted**. Use only your trusted private home network. Do not forward port 48921 to the internet. No files are recorded.
- This is locally ad-hoc signed, not Developer ID signed or notarized. macOS may ask you to approve opening it. Rebuilding can require granting audio capture permission again.
- Some apps or protected media may prevent capture. Spotify capture and audio quality need a real playback check with the system audio permission granted.

## Build and checks

Run `./build.command`. Requires Apple Command Line Tools with Swift 6 and a recent macOS SDK. It compiles for Apple silicon, packages the app, verifies its local signature, and runs the self-tests. Output: `dist/RoomAudio.app` and `dist/RoomAudio.zip`.

Self-tests cover known clock offsets, selection of the lowest round-trip sample under jitter, invalid clock input, bounded estimator history, PCM serialization, and a real local TCP handshake/audio exchange. They do not require audio capture permission and do not establish two-machine synchronization.

## Implementation

`Sources/Audio.swift` uses a private Core Audio process tap that includes only Spotify audio processes and mutes only Spotify’s original output while capture is active. The app then schedules its own delayed local playback through AVAudioEngine, preventing the main Mac from playing ahead of the receiver. Stopping destroys the private tap and aggregate device.

`Sources/Network.swift` handles bounded length-prefixed packets, pairing, clock estimation, and connection cleanup. Each audio buffer has a main-player monotonic clock deadline and a source-frame position. The receiver converts it to its own host clock before scheduling playback. Pending network/capture work is bounded. Local playback has a separate serial queue and never waits for network serialization. No external dependencies.

Apple reference: https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps

## Version 0.2 audio changes

Capture now uses the actual input stream format and explicitly matches the private aggregate sample rate to the Spotify tap. The buffer decoder reads the live channel counts, supports planar and interleaved stereo, and rejects malformed layouts. This prevents treating a mono channel as half as many stereo frames, which can change pitch and create discontinuities.

Playback anchors the first buffer to the shared clock and appends subsequent buffers contiguously instead of independently timing every buffer. A bounded, smoothed ±0.1% speed correction reconciles clock drift; real discontinuities reanchor using source frame positions. The local playback queue is independent of network encoding.

Additional tests synthesize known-frequency stereo signals, decode both buffer layouts, render continuously through AVAudioEngine at 44.1/48 kHz, convert to 48 kHz output, and check pitch, level, missing samples and discontinuities. These are offline signal tests; they do not establish that a particular physical output device is crackle-free.

Update the app on **both Macs** using the new ZIP, quit the old versions, then reconnect. The Spotify-only restriction is enforced at the source.
