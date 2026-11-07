using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using System.Text;
using RoomAudio.Core;

static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
var clock = new ClockSync();
Check(clock.Add(10, 110.01, 110.012, 10.022), "Valid clock sample rejected");
Check(Math.Abs(clock.Offset - 100) < 1e-8, "Clock offset incorrect");
clock.Add(11, 111.1, 111.102, 11.122);
Check(Math.Abs(clock.Offset - 100) < 1e-8, "Jitter replaced the best sample");
Check(!clock.Add(double.NaN, 1, 2, 3), "NaN clock accepted");
byte[] pcm = new byte[16];
BinaryPrimitives.WriteInt32LittleEndian(pcm, BitConverter.SingleToInt32Bits(.25f));
BinaryPrimitives.WriteInt32LittleEndian(pcm.AsSpan(4), BitConverter.SingleToInt32Bits(-.5f));
var packet = new Packet { Kind = "audio", At = 123.5, Rate = 48000, Frames = 2, Pcm = pcm, Position = 0 };
byte[] encoded = Framing.Encode(packet);
Check(BinaryPrimitives.ReadInt32BigEndian(encoded) == encoded.Length - 4, "Frame endianness mismatch");
await using (var stream = new MemoryStream(encoded)) {
    Packet decoded = await Framing.ReadAsync(stream, CancellationToken.None);
    Check(decoded.Pcm!.SequenceEqual(pcm) && decoded.At == 123.5 && decoded.Position == 0, "Mac protocol compatibility failed");
}
// Swift's Codable spelling and base64 representation, independent of our encoder.
byte[] swiftJson = Encoding.UTF8.GetBytes("{\"kind\":\"audio\",\"at\":123.5,\"rate\":48000,\"frames\":2,\"pcm\":\"AACAPgAAAL8AAAAAAAAAAA==\",\"position\":0}");
byte[] swiftFrame = new byte[swiftJson.Length + 4]; BinaryPrimitives.WriteInt32BigEndian(swiftFrame, swiftJson.Length); swiftJson.CopyTo(swiftFrame, 4);
await using (var stream = new MemoryStream(swiftFrame)) Check((await Framing.ReadAsync(stream, CancellationToken.None)).Pcm!.SequenceEqual(pcm), "Swift fixture PCM differs");
try { await Framing.ReadAsync(new MemoryStream(new byte[] { 0x7f, 0xff, 0xff, 0xff }), CancellationToken.None); throw new Exception("Oversized frame accepted"); } catch (InvalidDataException) { }
try { await Framing.ReadAsync(new MemoryStream(encoded[..^1]), CancellationToken.None); throw new Exception("Truncated frame accepted"); } catch (EndOfStreamException) { }

foreach (int rate in new[] { 44100, 48000 }) {
    var scheduler = new ScheduledPcm(rate);
    int total = rate * 2;
    for (int start = 0; start < total; start += 512) {
        int frames = Math.Min(512, total - start); byte[] audio = new byte[frames * 8];
        for (int i = 0; i < frames; ++i) for (int channel = 0; channel < 2; ++channel) {
            float sample = (float)(.3 * Math.Sin(2 * Math.PI * (channel == 0 ? 440 : 880) * (start + i) / rate));
            BinaryPrimitives.WriteInt32LittleEndian(audio.AsSpan((i * 2 + channel) * 4), BitConverter.SingleToInt32Bits(sample));
        }
        scheduler.Push(new Packet { Kind = "audio", At = 1000.0 + (double)start / rate, Rate = rate, Frames = frames, Pcm = audio, Position = start }, 1000.0 + (double)start / rate);
    }
    float[] output = new float[total * 2];
    for (int start = 0; start < total; start += 480) {
        int frames = Math.Min(480, total - start);
        scheduler.Render(output.AsSpan(start * 2, frames * 2), 1000.0 + (double)start / rate);
    }
    for (int channel = 0; channel < 2; ++channel) {
        int crossings = 0; float maxJump = 0; double sum = 0;
        for (int i = 1025; i < total - 512; ++i) {
            float a = output[(i - 1) * 2 + channel], b = output[i * 2 + channel];
            if (a <= 0 && b > 0) crossings++; maxJump = Math.Max(maxJump, Math.Abs(b - a)); sum += b * b;
        }
        double duration = (double)(total - 512 - 1025) / rate;
        Check(Math.Abs(crossings / duration - (channel == 0 ? 440 : 880)) < 1, "Pitch changed");
        Check(maxJump < .05, "Audible discontinuity between buffers");
        Check(Math.Abs(Math.Sqrt(sum / (total - 512 - 1025)) - .3 / Math.Sqrt(2)) < .005, "Channel energy changed");
    }
    Check(scheduler.Underruns == 0, "Continuous input underruns");
    Check(scheduler.BufferedFrames < 1024, "Rendered data was not retired");
}
// A real socket exchange validates the same framing used by Mac and Windows.
var listener = new TcpListener(IPAddress.Loopback, 0); listener.Start();
using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(5));
Task server = Task.Run(async () => {
    using var accepted = await listener.AcceptTcpClientAsync(cancellation.Token);
    await using var peer = new Peer(accepted.GetStream(), cancellation.Token);
    Packet hello = await peer.ReadAsync(cancellation.Token); Check(hello.Token == "123456", "Pairing token changed");
    peer.Send(packet);
    Check((await peer.ReadAsync(cancellation.Token)).Kind == "done", "Missing acknowledgement");
});
using (var client = new TcpClient()) {
    await client.ConnectAsync(IPAddress.Loopback, ((IPEndPoint)listener.LocalEndpoint).Port, cancellation.Token);
    await using var peer = new Peer(client.GetStream(), cancellation.Token);
    peer.Send(new Packet { Kind = "hello", Token = "123456" });
    Check((await peer.ReadAsync(cancellation.Token)).Pcm!.SequenceEqual(pcm), "TCP audio changed");
    peer.Send(new Packet { Kind = "done" }); await server;
}
listener.Stop();
Console.WriteLine("PASS: Swift wire compatibility; clock offset/jitter; malformed/truncated frames; live TCP pairing/audio; stereo 44.1/48 kHz pitch, energy and buffer continuity.");
