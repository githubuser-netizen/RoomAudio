using System.Net;
using System.Net.Sockets;
using NAudio.CoreAudioApi;
namespace RoomAudio.Windows;

static class Program
{
    [STAThread]
    static void Main() { ApplicationConfiguration.Initialize(); Application.Run(new MainForm()); }
}
sealed class MainForm : Form
{
    sealed record DeviceChoice(string Id, string Name) { public override string ToString() => Name; }
    readonly ComboBox role = new() { DropDownStyle = ComboBoxStyle.DropDownList, Dock = DockStyle.Fill, AccessibleName = "This PC’s role" };
    readonly ComboBox output = new() { DropDownStyle = ComboBoxStyle.DropDownList, Dock = DockStyle.Fill, AccessibleName = "Playback speakers" };
    readonly TextBox address = new() { Dock = DockStyle.Fill, PlaceholderText = "Main player’s Wi-Fi address", AccessibleName = "Main player address" };
    readonly TextBox code = new() { Dock = DockStyle.Fill, MaxLength = 6, PlaceholderText = "Six-digit room code", AccessibleName = "Room code" };
    readonly Label help = new() { AutoSize = true, MaximumSize = new Size(560, 0) };
    readonly Label status = new() { Text = "Ready. Choose a role to begin.", AutoSize = true, MaximumSize = new Size(560, 0), AccessibleName = "Connection status" };
    readonly CheckBox silent = new() { Text = "Spotify is routed to a separate silent output (main player only)", AutoSize = true, MaximumSize = new Size(560, 0) };
    readonly NumericUpDown timing = new() { Minimum = -200, Maximum = 200, Increment = 1, AccessibleName = "Room timing in milliseconds", Width = 100 };
    readonly Button start = new() { Text = "Connect", AutoSize = true };
    readonly Button stop = new() { Text = "Stop", AutoSize = true, Enabled = false };
    Session? session;
    bool busy, closing;
    public MainForm()
    {
        Text = "RoomAudio · Windows 11"; ClientSize = new Size(620, 650); MinimumSize = new Size(560, 650);
        AutoScaleMode = AutoScaleMode.Dpi; Font = new Font("Segoe UI", 10); Padding = new Padding(24);
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, AutoScroll = true };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); Controls.Add(layout);
        void Add(Control control) { control.Margin = new Padding(0, 0, 0, 14); layout.Controls.Add(control); }
        Add(new Label { Text = "Spotify in every room", Font = new Font(Font.FontFamily, 21, FontStyle.Bold), AutoSize = true });
        Add(new Label { Text = "Share Spotify from this PC, or receive from a Mac or another PC.", AutoSize = true, MaximumSize = new Size(560, 0) });
        role.Items.AddRange(["Receiver", "Main Spotify player"]); role.SelectedIndex = 0; Add(role);
        Add(help); Add(new Label { Text = "Play through", AutoSize = true }); Add(output);
        Add(address); Add(code); Add(silent);
        var offset = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Top };
        offset.Controls.Add(new Label { Text = "Room timing (ms)", AutoSize = true, Margin = new Padding(0, 5, 12, 0) }); offset.Controls.Add(timing); Add(offset);
        Add(new Label { Text = "If this room sounds late, use a negative value. If early, use a positive value. Built-in or wired speakers work best.", AutoSize = true, MaximumSize = new Size(560, 0) });
        var actions = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Top }; actions.Controls.Add(start); actions.Controls.Add(stop); Add(actions); Add(status);
        Add(new Label { Text = "Trusted private Wi-Fi only. Audio is not encrypted. Clock estimates do not measure acoustic speaker sync. Changing output devices requires Stop and reconnect.", AutoSize = true, MaximumSize = new Size(560, 0), ForeColor = SystemColors.GrayText });
        role.SelectedIndexChanged += (_, _) => UpdateRole();
        timing.ValueChanged += (_, _) => { if (session is not null) session.OffsetMs = (double)timing.Value; };
        start.Click += async (_, _) => await StartAsync();
        stop.Click += async (_, _) => await StopAsync("Stopped.");
        FormClosing += async (_, e) => { if (!closing && session is not null) { e.Cancel = true; await StopAsync("Stopped."); closing = true; Close(); } };
        AcceptButton = start; CancelButton = stop;
        LoadDevices(); UpdateRole();
    }
    void LoadDevices()
    {
        try {
            using var devices = new MMDeviceEnumerator();
            using var defaultDevice = devices.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            int index = 0;
            foreach (MMDevice device in devices.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active)) {
                using (device) { output.Items.Add(new DeviceChoice(device.ID, device.FriendlyName)); if (device.ID == defaultDevice.ID) index = output.Items.Count - 1; }
            }
            if (output.Items.Count > 0) output.SelectedIndex = index;
        } catch (Exception e) { status.Text = "Cannot find speakers: " + e.Message; }
    }
    void UpdateRole()
    {
        bool host = role.SelectedIndex == 1;
        address.Visible = !host; code.Visible = !host; silent.Visible = host;
        help.Text = host ? "Before sharing, route ONLY Spotify to a silent/virtual playback device in Windows Settings → Sound → Volume mixer. Choose your real speakers below. RoomAudio supplies synchronized local playback; WhatsApp alerts stay local." : "On the main player, start sharing and copy its address and room code here. Keep Spotify stopped on this receiver.";
        start.Text = host ? "Start sharing" : "Connect";
    }
    void Post(Action action) { if (!IsDisposed && IsHandleCreated) BeginInvoke(action); }
    async Task StartAsync()
    {
        if (busy || output.SelectedItem is not DeviceChoice device) return;
        bool host = role.SelectedIndex == 1;
        if (host && !silent.Checked) { status.Text = "First route Spotify to a silent output and check the confirmation above."; return; }
        if (!host && (string.IsNullOrWhiteSpace(address.Text) || code.Text.Length != 6)) { status.Text = "Enter the main player’s address and six-digit room code."; return; }
        busy = true; start.Enabled = false; role.Enabled = output.Enabled = address.Enabled = code.Enabled = silent.Enabled = false;
        var current = new Session(device.Id) { OffsetMs = (double)timing.Value }; session = current;
        current.Status += message => Post(() => { if (session == current) status.Text = message; });
        current.Failed += message => Post(async () => { if (session == current) await StopAsync(message); });
        try {
            status.Text = host ? "Opening Spotify capture…" : "Connecting…";
            if (host) {
                await current.HostAsync(device.Id);
                string ips = string.Join(" or ", Dns.GetHostAddresses(Dns.GetHostName()).Where(ip => ip.AddressFamily == AddressFamily.InterNetwork).Select(ip => ip.ToString()));
                help.Text = $"Main player address: {ips}\nRoom code: {current.Code}\nOnly Spotify is shared. Other applications stay local. Route Spotify back to your speakers when finished.";
            } else await current.JoinAsync(address.Text.Trim(), code.Text.Trim());
            stop.Enabled = true;
        } catch (Exception e) { await StopAsync(e.Message); }
    }
    async Task StopAsync(string message)
    {
        Session? old = session; session = null; stop.Enabled = false;
        if (old is not null) { try { await old.DisposeAsync(); } catch (Exception e) { message += " Cleanup: " + e.Message; } }
        busy = false; role.Enabled = output.Enabled = address.Enabled = code.Enabled = silent.Enabled = true; start.Enabled = true;
        UpdateRole(); status.Text = message;
    }
}
