using System.Buffers.Binary;
using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading.Channels;

namespace RoomAudio.Core;
public static class Monotonic { public static double Now => (double)Stopwatch.GetTimestamp() / Stopwatch.Frequency; }
public sealed record Packet
{
    public required string Kind { get; init; }
    public string? Token { get; init; }
    public double? T1 { get; init; }
    public double? T2 { get; init; }
    public double? T3 { get; init; }
    public double? At { get; init; }
    public double? Rate { get; init; }
    public int? Frames { get; init; }
    public byte[]? Pcm { get; init; }
    public long? Position { get; init; }
}
public static class Framing
{
    public const int MaxLength = 256000;
    public static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull };
    public static byte[] Encode(Packet packet)
    {
        byte[] json = JsonSerializer.SerializeToUtf8Bytes(packet, Json);
        if (json.Length == 0 || json.Length >= MaxLength) throw new InvalidDataException("Packet too large");
        byte[] frame = new byte[json.Length + 4];
        BinaryPrimitives.WriteInt32BigEndian(frame, json.Length);
        json.CopyTo(frame, 4); return frame;
    }
    public static async ValueTask<Packet> ReadAsync(Stream stream, CancellationToken cancellation)
    {
        byte[] header = new byte[4];
        await stream.ReadExactlyAsync(header, cancellation);
        int size = BinaryPrimitives.ReadInt32BigEndian(header);
        if (size <= 0 || size >= MaxLength) throw new InvalidDataException("Invalid packet length");
        byte[] payload = new byte[size];
        await stream.ReadExactlyAsync(payload, cancellation);
        return JsonSerializer.Deserialize<Packet>(payload, Json) ?? throw new InvalidDataException("Invalid packet");
    }
}
public sealed class Peer : IAsyncDisposable
{
    readonly Stream stream;
    readonly Channel<Packet> outgoing = Channel.CreateBounded<Packet>(new BoundedChannelOptions(32) { SingleReader = true, FullMode = BoundedChannelFullMode.Wait });
    readonly CancellationTokenSource stop;
    readonly Task writer;
    int disposed;
    public Peer(Stream stream, CancellationToken cancellation)
    {
        this.stream = stream; stop = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        writer = WriteLoopAsync();
    }
    public bool Send(Packet packet)
    {
        if (Volatile.Read(ref disposed) != 0) return false;
        if (outgoing.Writer.TryWrite(packet)) return true;
        try { stop.Cancel(); } catch (ObjectDisposedException) { }
        stream.Close(); return false;
    }
    async Task WriteLoopAsync()
    {
        try {
            await foreach (Packet packet in outgoing.Reader.ReadAllAsync(stop.Token))
                await stream.WriteAsync(Framing.Encode(packet), stop.Token);
        } catch (Exception e) when (e is IOException or OperationCanceledException or ObjectDisposedException) {
            stop.Cancel(); stream.Close();
        }
    }
    public ValueTask<Packet> ReadAsync(CancellationToken cancellation) => Framing.ReadAsync(stream, cancellation);
    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0) return;
        stop.Cancel(); outgoing.Writer.TryComplete(); stream.Close();
        await writer; stop.Dispose();
    }
}
public sealed class ClockSync
{
    readonly List<(double Offset, double Rtt)> samples = [];
    public int Count => samples.Count;
    public double Offset => samples.Count == 0 ? 0 : samples.MinBy(x => x.Rtt).Offset;
    public double UncertaintyMs => samples.Count == 0 ? 0 : samples.Min(x => x.Rtt) * 500;
    public bool Add(double t1, double t2, double t3, double t4)
    {
        double rtt = t4 - t1 - (t3 - t2);
        if (!double.IsFinite(t1) || !double.IsFinite(t2) || !double.IsFinite(t3) || !double.IsFinite(t4) || rtt < 0 || rtt >= .5) return false;
        samples.Add((((t2 - t1) + (t3 - t4)) / 2, rtt));
        if (samples.Count > 32) samples.RemoveAt(0);
        return true;
    }
}
