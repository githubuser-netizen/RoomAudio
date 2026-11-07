using System.Buffers.Binary;
namespace RoomAudio.Core;

// Hardware callbacks read continuously. Network arrival jitter never schedules separate
// sound-device buffers or changes sample rate. Linear interpolation reconciles tiny drift.
public sealed class ScheduledPcm(int rate)
{
    sealed record Block(long Start, float[] Samples) { public long End => Start + Samples.Length / 2; }
    readonly object gate = new();
    readonly LinkedList<Block> blocks = [];
    double? referenceTime;
    double? cursor;
    long fallbackPosition;
    float gain, lastLeft, lastRight;
    long underruns;
    public int Rate { get; } = rate is >= 8000 and <= 192000 ? rate : throw new ArgumentOutOfRangeException(nameof(rate));
    public long Underruns { get { lock (gate) return underruns; } }
    public int BufferedFrames { get { lock (gate) return blocks.Sum(b => b.Samples.Length / 2); } }
    public void Push(Packet packet, double localDeadline)
    {
        if (packet.Pcm is not byte[] data || packet.Frames is not int count || count <= 0 || count > 16384 || data.Length != count * 8 || packet.Rate != Rate || !double.IsFinite(localDeadline))
            throw new InvalidDataException("Unsupported audio packet");
        float[] samples = new float[count * 2];
        for (int i = 0; i < samples.Length; ++i) {
            float value = BitConverter.Int32BitsToSingle(BinaryPrimitives.ReadInt32LittleEndian(data.AsSpan(i * 4, 4)));
            samples[i] = float.IsFinite(value) ? value : 0;
        }
        lock (gate) {
            long position = packet.Position ?? fallbackPosition;
            if (position < 0 || position > long.MaxValue - count) throw new InvalidDataException("Invalid source position");
            if (blocks.Last is not null && position < blocks.Last.Value.End) return;
            double measuredReference = localDeadline - (double)position / Rate;
            if (referenceTime is null || Math.Abs(measuredReference - referenceTime.Value) > .1) {
                blocks.Clear(); cursor = null; referenceTime = measuredReference; gain = 0;
            } else {
                // NTP selection changes are smoothed; the render callback further limits slew.
                referenceTime += Math.Clamp(measuredReference - referenceTime.Value, -.001, .001) * .05;
            }
            blocks.AddLast(new Block(position, samples)); fallbackPosition = position + count;
            while (blocks.First is not null && blocks.Last!.Value.End - blocks.First.Value.Start > Rate * 3) blocks.RemoveFirst();
        }
    }
    public void Render(Span<float> output, double firstFrameDeadline)
    {
        if (output.Length % 2 != 0 || !double.IsFinite(firstFrameDeadline)) throw new ArgumentException("Stereo frames and a finite deadline required");
        lock (gate) {
            output.Clear();
            if (referenceTime is null) return;
            double desired = (firstFrameDeadline - referenceTime.Value) * Rate;
            if (cursor is null || Math.Abs(desired - cursor.Value) > Rate * .05) { cursor = desired; gain = 0; }
            int frames = output.Length / 2;
            double step = 1 + Math.Clamp((desired - cursor.Value) / Math.Max(frames, 1) * .02, -.001, .001);
            bool missing = false;
            for (int i = 0; i < frames; ++i) {
                long frame = (long)Math.Floor(cursor.Value);
                while (blocks.First is not null && blocks.First.Value.End <= frame) blocks.RemoveFirst();
                bool found = TrySample(frame, out float l, out float r);
                if (found) {
                    double fraction = cursor.Value - frame;
                    if (TrySample(frame + 1, out float nextL, out float nextR)) { l += (nextL - l) * (float)fraction; r += (nextR - r) * (float)fraction; }
                    lastLeft = l; lastRight = r; gain = Math.Min(1, gain + 1f / 240);
                } else {
                    gain = Math.Max(0, gain - 1f / 240);
                    if (frame >= fallbackPosition || (blocks.First is not null && frame >= blocks.First.Value.Start)) missing = true;
                }
                output[i * 2] = lastLeft * gain; output[i * 2 + 1] = lastRight * gain;
                cursor += step;
            }
            if (missing) underruns++;
        }
    }
    bool TrySample(long frame, out float left, out float right)
    {
        for (var node = blocks.First; node is not null; node = node.Next) {
            if (frame < node.Value.Start) break;
            if (frame < node.Value.End) {
                int index = checked((int)(frame - node.Value.Start) * 2);
                left = node.Value.Samples[index]; right = node.Value.Samples[index + 1]; return true;
            }
        }
        left = right = 0; return false;
    }
}
