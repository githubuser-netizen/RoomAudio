# RoomAudio for Windows 11

Experimental Windows main player and receiver compatible with the Mac RoomAudio v0.2 protocol. WhatsApp, browser and system alerts are never captured: hosting uses Spotify's process tree only.

## Download/build

Use the x64 package for most Intel/AMD Windows 11 PCs; use ARM64 for Windows on ARM. Unzip the entire package and open `RoomAudio.Windows.exe`. The packages are self-contained; no separate .NET installation is needed to run them. They are unsigned and have not been hardware-tested on Windows yet.

To build from source, install the .NET 10 SDK, then run PowerShell from the repository root:

```powershell
./Windows/build.ps1
```

The script runs the portable tests and publishes both `win-x64` and `win-arm64` packages into `dist/`. Pass `-Runtimes win-x64` to build only the common x64 version.

## Receiver: Mac or PC → Windows

1. Start sharing on the main Mac or Windows PC.
2. Open RoomAudio on Windows and select **Receiver**.
3. Choose the speakers you want to use, enter the main player's Wi-Fi address and six-digit room code, then connect.
4. Allow RoomAudio on your **private** network if Windows Firewall asks. Hosting uses inbound TCP port 48921; receiving connects to that port.
5. Use the timing adjustment if the room sounds early or late. Built-in or wired speakers work best.

A virtual audio device is **not** needed for receiver mode.

## Main player: Windows → Mac or PC

Windows process loopback does not provide the Mac's mute-while-capturing behavior. To avoid Spotify playing once immediately and again through RoomAudio's synchronized buffer, Spotify must play into a separate silent output.

1. Set up a silent playback endpoint, for example [VB-Audio's official VB-CABLE driver](https://vb-audio.com/Cable/). Installation is a separate user-managed step. No driver is installed or bundled by RoomAudio.
2. Keep Windows' default output on your real speakers. Open Spotify and play a track.
3. In **Settings → System → Sound → Volume mixer → Spotify**, choose the virtual cable's **playback/input** endpoint as Spotify's output. Route **only Spotify** there. Keep RoomAudio and other apps on the real speakers. Do not enable a cable monitoring/“Listen to this device” feature.
4. In RoomAudio choose **Main Spotify player**, select your real speakers, confirm Spotify is routed to a silent output, and start sharing.
5. On the receiving Macs or PCs, enter the address and code shown on Windows. Keep Spotify running only on the main PC.
6. When finished, Stop and set Spotify's output back to your speakers in Windows Volume mixer. RoomAudio never changes these saved Windows routing settings itself.

RoomAudio checks that Spotify is not routed directly to its selected speakers and that Spotify has an audio session on another endpoint. It cannot determine whether another physical endpoint is audible: use a genuinely silent endpoint. Hosting stops if Spotify closes or is moved to RoomAudio's speaker endpoint. There is no fallback to whole-system audio capture.

## Audio and compatibility limits

- Windows 11, x64 or ARM64. Uses .NET 10 and NAudio.Wasapi 3.3.0, with native WASAPI process-loopback capture and shared-mode playback.
- Main-player capture uses stereo 48 kHz floating-point PCM. The receiver also accepts 44.1 kHz Mac streams. Windows handles output device sample-rate conversion.
- The source supplies 800 ms deadlines. Four-timestamp clock checks map those deadlines across machines. A continuous sample timeline with interpolation, bounded clock-drift correction and short fades avoids per-packet playback gaps.
- Windows hardware output latency varies. The hardware audio position is used for clock calibration; adjust room timing by ear. Network clock estimates do not establish acoustic synchronization.
- Only trusted private networks: PCM is paired by room code but **not encrypted**. Do not expose the listening port to the internet. Audio is not saved to a recording.
- Changing playback devices or recovering from sleep requires Stop and reconnect. The PC must remain awake while sharing or receiving; Windows sleep policy is not modified.

## Verification

Both Windows architectures are cross-compiled from macOS. Portable tests execute on macOS and validate wire framing compatible with Swift Codable, known clock offsets and jitter, malformed/truncated packets, a live TCP audio exchange, and two-channel 44.1/48 kHz sine-wave pitch, level and continuity. The existing Mac audio tests also pass.

**Not yet verified:** real Windows audio devices, Spotify process loopback, silent endpoint routing, acoustic Mac/PC synchronization and the Windows user interface. Those require a Windows 11 PC; a successful cross-build is not a hardware test.

Sources: [Microsoft process loopback sample](https://learn.microsoft.com/en-us/samples/microsoft/windows-classic-samples/applicationloopbackaudio-sample/), [NAudio recorder](https://github.com/naudio/NAudio/blob/main/Docs/WasapiRecorder.md), [NAudio player](https://github.com/naudio/NAudio/blob/main/Docs/WasapiPlayer.md).
