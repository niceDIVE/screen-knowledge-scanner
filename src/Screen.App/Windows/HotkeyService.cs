using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace Screen.App.Windows;

public sealed class HotkeyService(ScannerOptions options, KnowledgeStore store, ScrollCoordinator scroll,
    IRegionPicker picker, ILogger<HotkeyService> log) : IHostedService
{
    /// <summary>热键定义：Id 对应 WndProc 的 wParam，ConfigKey 对应 Scanner:HotkeyKeys 下的字段名。</summary>
    private static readonly (int Id, string Action, string ConfigKey)[] Definitions =
    {
        (1, "单帧截图", "Capture"),
        (2, "滚动采集", "Scroll"),
        (3, "停止采集", "Stop"),
        (4, "框选区域", "Region"),
    };

    private Thread? thread;
    private HotkeyWindow? window;

    public Task StartAsync(CancellationToken token)
    {
        if (!options.Hotkeys) return Task.CompletedTask;
        var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        thread = new Thread(() =>
        {
            try
            {
                using var form = new HotkeyWindow(Dispatch, log, options);
                window = form;
                _ = form.Handle;
                ready.TrySetResult();
                System.Windows.Forms.Application.Run(form);
            }
            catch (Exception ex) { log.LogError(ex, "Hotkey loop failed"); ready.TrySetException(ex); }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.IsBackground = true;
        thread.Start();
        return ready.Task;
    }

    private void Dispatch(int id) => _ = Task.Run(async () =>
    {
        try
        {
            if (id == 3) { await scroll.StopAsync(); return; }
            if (id == 4) { var region = await picker.PickAsync(); if (region is not null) store.SetRegion(region); return; }
            var run = store.Runs().FirstOrDefault(r => r.State == "open") ?? store.CreateRun($"桌面采集 {DateTime.Now:MM-dd HH:mm}");
            if (id == 1) scroll.Single(run.Id, store.GetRegion());
            if (id == 2) scroll.Start(new(run.Id, store.GetRegion()), waitForFocus: false);
        }
        catch (Exception ex) { log.LogWarning(ex, "Hotkey action failed: {Message}", ex.Message); }
    });

    public Task StopAsync(CancellationToken token)
    {
        if (window is { IsDisposed: false, IsHandleCreated: true }) window.BeginInvoke((Action)window.Close);
        thread?.Join(2000);
        return Task.CompletedTask;
    }

    /// <summary>解析 "Ctrl+Alt+S" → modifiers + virtual-key（实现见跨平台的 HotkeyParser）。</summary>
    public static bool TryParse(string? combo, out uint modifiers, out uint key, out string problem)
        => HotkeyParser.TryParse(combo, out modifiers, out key, out problem);

    private sealed class HotkeyWindow(Action<int> dispatch, ILogger log, ScannerOptions options) : Form
    {
        [DllImport("user32.dll")] private static extern bool RegisterHotKey(nint window, int id, uint mods, uint key);
        [DllImport("user32.dll")] private static extern bool UnregisterHotKey(nint window, int id);

        protected override void SetVisibleCore(bool value) => base.SetVisibleCore(false);

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            var combos = new Dictionary<int, string>
            {
                [1] = options.HotkeyKeys.Capture,
                [2] = options.HotkeyKeys.Scroll,
                [3] = options.HotkeyKeys.Stop,
                [4] = options.HotkeyKeys.Region,
            };
            foreach (var (id, action, configKey) in Definitions)
            {
                var combo = combos[id];
                if (!TryParse(combo, out var mods, out var key, out var problem))
                {
                    log.LogWarning("热键配置无效：{Action} 的组合键 \"{Combo}\" 无法解析（{Problem}）；请修改 appsettings.json 的 Scanner:HotkeyKeys:{ConfigKey}",
                        action, combo, problem, configKey);
                    continue;
                }
                if (!RegisterHotKey(Handle, id, mods, key))
                {
                    log.LogWarning("热键 {Combo}（{Action}）注册失败：可能已被其他程序占用；可在 appsettings.json 的 Scanner:HotkeyKeys:{ConfigKey} 改键，或从页面用「框选区域」按钮替代",
                        combo, action, configKey);
                }
            }
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == 0x0312) dispatch((int)m.WParam);
            base.WndProc(ref m);
        }

        protected override void OnHandleDestroyed(EventArgs e)
        {
            for (var id = 1; id <= 4; id++) UnregisterHotKey(Handle, id);
            base.OnHandleDestroyed(e);
        }
    }
}
