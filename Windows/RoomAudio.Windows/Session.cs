using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Threading.Channels;
using RoomAudio.Core;
namespace RoomAudio.Windows;

sealed class Session : IAsyncDisposable
{
    readonly CancellationTokenSource stop = new();
    readonly ConcurrentDictionary<Guid, Peer> peers = new();
    readonly ConcurrentBag<Task> jobs = [];
    readonly AudioOutput output;
    SpotifyCapture? capture;
    TcpListener? listener;
    TcpClient? client;
    public string Code { get; } = RandomNumberGenerator.GetInt32(100000, 1000000).ToString();
    public event Action<string>? Status;
    public event Action<string>? Failed;
    public Session(string deviceId) { output = new AudioOutput(deviceId); }
    public double OffsetMs { set => output.OffsetMs = value; }
    public async Task HostAsync(string deviceId)
    {
        capture = new SpotifyCapture(deviceId);
        var networkAudio = Channel.CreateBounded<Packet>(new BoundedChannelOptions(32) { SingleReader = true, FullMode = BoundedChannelFullMode.Wait });
        // Do not block local audio on network serialization or a stalled receiver.
        capture.Audio += packet => {
            try {
                output.Push(packet, packet.At!.Value);
                if (!networkAudio.Writer.TryWrite(packet)) {
                    foreach (Peer peer in peers.Values) _ = peer.DisposeAsync();
                    peers.Clear();
                }
            } catch (Exception e) { Fail(e.Message); }
        };
        capture.Failed += Fail;
        await capture.StartAsync(stop.Token);
        listener = new TcpListener(IPAddress.Any, 48921);
        listener.Start(4);
        jobs.Add(Task.Run(async () => {
            try {
                while (!stop.IsCancellationRequested) {
                    TcpClient connected = await listener.AcceptTcpClientAsync(stop.Token);
                    if (peers.Count >= 4) { connected.Dispose(); continue; }
                    jobs.Add(ServeAsync(connected));
                }
            } catch (Exception e) when (e is OperationCanceledException or SocketException or ObjectDisposedException) { }
        }));
        jobs.Add(Task.Run(async () => {
            try {
                await foreach (Packet packet in networkAudio.Reader.ReadAllAsync(stop.Token))
                    foreach (Peer peer in peers.Values) peer.Send(packet);
            } catch (OperationCanceledException) { }
        }));
        jobs.Add(Task.Run(async () => {
            try {
                using var timer = new PeriodicTimer(TimeSpan.FromMilliseconds(100));
                int ticks = 0;
                while (await timer.WaitForNextTickAsync(stop.Token)) {
                    output.Calibrate();
                    if (++ticks % 10 == 0) {
                        capture.ValidateRouting();
                        Status?.Invoke($"Spotify only · 48 kHz · {peers.Count} receiver(s) · {output.Underruns} underrun blocks");
                    }
                }
            } catch (OperationCanceledException) { } catch (Exception e) { Fail(e.Message); }
        }));
        Status?.Invoke("Sharing Spotify only. Other apps stay local.");
    }
    async Task ServeAsync(TcpClient connected)
    {
        Guid id = Guid.NewGuid();
        connected.NoDelay = true;
        await using var peer = new Peer(connected.GetStream(), stop.Token);
        try {
            using var handshake = CancellationTokenSource.CreateLinkedTokenSource(stop.Token);
            handshake.CancelAfter(TimeSpan.FromSeconds(10));
            Packet hello = await peer.ReadAsync(handshake.Token);
            if (hello.Kind != "hello" || hello.Token != Code) return;
            peers[id] = peer;
            peer.Send(new Packet { Kind = "welcome" });
            while (!stop.IsCancellationRequested) {
                Packet packet = await peer.ReadAsync(stop.Token);
                double received = Monotonic.Now;
                if (packet.Kind == "ping" && packet.T1 is double t1 && double.IsFinite(t1))
                    peer.Send(new Packet { Kind = "pong", T1 = t1, T2 = received, T3 = Monotonic.Now });
            }
        } catch (Exception e) when (e is IOException or OperationCanceledException or ObjectDisposedException or InvalidDataException or System.Text.Json.JsonException) { }
        finally { peers.TryRemove(id, out _); connected.Dispose(); }
    }
    public async Task JoinAsync(string address, string code)
    {
        client = new TcpClient { NoDelay = true };
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(stop.Token);
        timeout.CancelAfter(TimeSpan.FromSeconds(12));
        await client.ConnectAsync(address, 48921, timeout.Token);
        var peer = new Peer(client.GetStream(), stop.Token);
        peer.Send(new Packet { Kind = "hello", Token = code });
        Packet welcome = await peer.ReadAsync(timeout.Token);
        if (welcome.Kind != "welcome") throw new InvalidDataException("The main player rejected the room code.");
        peers[Guid.Empty] = peer;
        var clock = new ClockSync();
        var outstanding = new ConcurrentDictionary<double, byte>();
        jobs.Add(Task.Run(async () => {
            try {
                using var timer = new PeriodicTimer(TimeSpan.FromMilliseconds(200));
                int count = 0;
                while (await timer.WaitForNextTickAsync(stop.Token)) {
                    double stamp = Monotonic.Now;
                    if (++count < 15 || count % 5 == 0) {
                        foreach (double old in outstanding.Keys) if (stamp - old > 5) outstanding.TryRemove(old, out _);
                        outstanding[stamp] = 0; peer.Send(new Packet { Kind = "ping", T1 = stamp });
                    }
                    output.Calibrate();
                }
            } catch (OperationCanceledException) { } catch (Exception e) { Fail(e.Message); }
        }));
        jobs.Add(Task.Run(async () => {
            try {
                while (!stop.IsCancellationRequested) {
                    Packet packet = await peer.ReadAsync(stop.Token);
                    if (packet.Kind == "pong" && packet.T1 is double t1 && packet.T2 is double t2 && packet.T3 is double t3 && outstanding.TryRemove(t1, out _)) {
                        clock.Add(t1, t2, t3, Monotonic.Now);
                        Status?.Invoke(clock.Count < 5 ? "Aligning clocks…" : $"Connected · clock estimate ±{clock.UncertaintyMs:F1} ms · {output.Underruns} underrun blocks");
                    } else if (packet.Kind == "audio" && clock.Count >= 5 && packet.At is double at && double.IsFinite(at)) {
                        output.Push(packet, at - clock.Offset);
                    }
                }
            } catch (Exception e) when (e is IOException or OperationCanceledException or ObjectDisposedException) {
                if (!stop.IsCancellationRequested) Fail("Connection closed. Check the address and room code, then reconnect.");
            } catch (Exception e) { Fail(e.Message); }
        }));
        Status?.Invoke("Connected. Aligning clocks…");
    }
    void Fail(string message) { if (!stop.IsCancellationRequested) { stop.Cancel(); Failed?.Invoke(message); } }
    public async ValueTask DisposeAsync()
    {
        stop.Cancel(); listener?.Stop(); client?.Dispose();
        if (capture is not null) await capture.DisposeAsync();
        foreach (Peer peer in peers.Values) await peer.DisposeAsync(); peers.Clear();
        try { await Task.WhenAll(jobs.ToArray()); } catch (OperationCanceledException) { }
        output.Dispose(); stop.Dispose();
    }
}
