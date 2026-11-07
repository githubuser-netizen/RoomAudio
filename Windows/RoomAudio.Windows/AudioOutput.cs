using NAudio.CoreAudioApi;
using NAudio.Wave;
using RoomAudio.Core;
namespace RoomAudio.Windows;

sealed class AudioOutput : IDisposable
{
    readonly object gate = new();
    readonly string deviceId;
    WasapiPlayer? player;
    Provider? provider;
    double offsetMs;
    public AudioOutput(string deviceId) { this.deviceId = deviceId; }
    public double OffsetMs { set { lock (gate) offsetMs = value; } }
    public long Underruns { get { lock (gate) return provider?.Pcm.Underruns ?? 0; } }
    public void Push(Packet packet, double deadline)
    {
        lock (gate) {
            if (packet.Rate is not double raw || raw != Math.Truncate(raw) || raw < 8000 || raw > 192000) throw new InvalidDataException("Invalid sample rate");
            int rate = (int)raw;
            if (provider?.Pcm.Rate != rate) {
                DisposePlayer();
                provider = new Provider(rate);
                using var devices = new MMDeviceEnumerator();
                using var device = devices.GetDevice(deviceId);
                player = new WasapiPlayerBuilder().WithDevice(device).WithSharedMode().WithLatency(40).WithMmcssThreadPriority("Pro Audio").Build();
                player.Init(provider.ToWaveProvider());
                provider.OutputAnchor = Monotonic.Now;
                player.Play();
            }
            provider!.Pcm.Push(packet, deadline + offsetMs / 1000);
        }
    }
    // A separate control timer maps the hardware clock to the same monotonic clock
    // used by network synchronization. The audio callback only takes a short PCM lock.
    public void Calibrate()
    {
        lock (gate) {
            if (player is null || provider is null) return;
            double played = (double)player.GetPosition() / player.OutputWaveFormat.AverageBytesPerSecond;
            if (played > 0) provider.Calibrate(Monotonic.Now - played);
        }
    }
    void DisposePlayer() { player?.Stop(); player?.Dispose(); player = null; provider = null; }
    public void Dispose() { lock (gate) DisposePlayer(); }
    sealed class Provider(int rate) : ISampleProvider
    {
        public ScheduledPcm Pcm { get; } = new(rate);
        public WaveFormat WaveFormat { get; } = WaveFormat.CreateIeeeFloatWaveFormat(rate, 2);
        double anchor;
        long rendered;
        public double OutputAnchor { set => Volatile.Write(ref anchor, value); }
        public void Calibrate(double measured)
        {
            double current = Volatile.Read(ref anchor);
            Volatile.Write(ref anchor, current + Math.Clamp(measured - current, -.002, .002) * .1);
        }
        public int Read(Span<float> samples)
        {
            Pcm.Render(samples, Volatile.Read(ref anchor) + (double)rendered / rate);
            rendered += samples.Length / 2;
            return samples.Length;
        }
    }
}
