using System.Diagnostics;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using RoomAudio.Core;
namespace RoomAudio.Windows;

sealed class SpotifyCapture : IAsyncDisposable
{
    WasapiRecorder? recorder;
    Process? spotify;
    readonly string outputId;
    public event Action<Packet>? Audio;
    public event Action<string>? Failed;
    public SpotifyCapture(string outputId) { this.outputId = outputId; }
    public async Task StartAsync(CancellationToken cancellation)
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000)) throw new NotSupportedException("Windows 11 is required.");
        Process[] candidates = Process.GetProcessesByName("Spotify");
        spotify = candidates.FirstOrDefault(p => p.MainWindowHandle != IntPtr.Zero);
        foreach (Process process in candidates) if (process != spotify) process.Dispose();
        if (spotify is null) throw new InvalidOperationException("Open the Spotify desktop app with its main window visible, play a track, then try again.");
        ValidateRouting();
        // No endpoint-wide capture API is used. Only this Spotify process tree enters the stream.
        recorder = await new WasapiRecorderBuilder()
            .WithProcessLoopback((uint)spotify.Id, ProcessLoopbackMode.IncludeTargetProcessTree)
            .WithFormat(WaveFormat.CreateIeeeFloatWaveFormat(48000, 2))
            .WithBufferLength(20).WithMmcssThreadPriority("Pro Audio").BuildAsync();
        cancellation.ThrowIfCancellationRequested();
        long position = 0;
        recorder.DataAvailable += (buffer, flags, devicePosition, qpcPosition) => {
            if (cancellation.IsCancellationRequested) return;
            int totalFrames = buffer.Length / 8;
            // WASAPI capture QPC is already expressed in 100 ns units since boot.
            double stamp = qpcPosition > 0 ? qpcPosition / 10000000.0 : Monotonic.Now - totalFrames / 48000.0;
            for (int frame = 0; frame < totalFrames; frame += 2048) {
                int count = Math.Min(2048, totalFrames - frame);
                byte[] copy = buffer.Slice(frame * 8, count * 8).ToArray();
                Audio?.Invoke(new Packet { Kind = "audio", At = stamp + frame / 48000.0 + .8, Rate = 48000, Frames = count, Pcm = copy, Position = position });
                position += count;
            }
        };
        recorder.RecordingStopped += (_, args) => { if (args.Exception is not null) Failed?.Invoke(args.Exception.Message); };
        recorder.StartRecording();
    }
    public void ValidateRouting()
    {
        if (spotify is not null && spotify.HasExited) throw new InvalidOperationException("Spotify closed. Reopen Spotify and restart sharing.");
        bool foundSeparateOutput = false;
        using var devices = new MMDeviceEnumerator();
        foreach (MMDevice device in devices.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active)) {
            using (device) {
                var manager = device.AudioSessionManager;
                manager.RefreshSessions();
                for (int i = 0; i < manager.Sessions.Count; ++i) {
                    using var session = manager.Sessions[i];
                    try {
                        using var process = Process.GetProcessById((int)session.GetProcessID);
                        if (!string.Equals(process.ProcessName, "Spotify", StringComparison.OrdinalIgnoreCase)) continue;
                        if (device.ID == outputId) throw new InvalidOperationException("Spotify is still playing directly to these speakers. In Windows Settings → System → Sound → Volume mixer, route ONLY Spotify to your silent/virtual output, then retry. Leave RoomAudio and other apps on your speakers.");
                        foundSeparateOutput = true;
                    } catch (ArgumentException) { /* Session ended while enumerating. */ }
                }
            }
        }
        if (!foundSeparateOutput) throw new InvalidOperationException("No separate Spotify output was found. Play a track and route Spotify to a silent/virtual output in Windows Volume mixer before sharing.");
    }
    public async ValueTask DisposeAsync()
    {
        if (recorder is not null) { recorder.StopRecording(); await recorder.DisposeAsync(); recorder = null; }
        spotify?.Dispose(); spotify = null;
    }
}
