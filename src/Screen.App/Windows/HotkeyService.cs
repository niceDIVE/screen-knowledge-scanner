using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace Screen.App.Windows;

public sealed class HotkeyService(KnowledgeStore store,ScrollCoordinator scroll,IRegionPicker picker,ILogger<HotkeyService> log) : IHostedService
{
    private Thread? thread; private HotkeyWindow? window;
    public Task StartAsync(CancellationToken token)
    {
        var ready=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        thread=new Thread(()=> {
            try
            {
                using var form=new HotkeyWindow(Dispatch,log); window=form;
                _=form.Handle; ready.TrySetResult(); System.Windows.Forms.Application.Run(form);
            }
            catch(Exception ex) { log.LogError(ex,"Hotkey loop failed"); ready.TrySetException(ex); }
        });
        thread.SetApartmentState(ApartmentState.STA); thread.IsBackground=true; thread.Start(); return ready.Task;
    }
    private void Dispatch(int id) => _=Task.Run(async()=> {
        try
        {
            if(id==3) { await scroll.StopAsync(); return; }
            if(id==4) { var region=await picker.PickAsync(); if(region is not null) store.SetRegion(region); return; }
            var run=store.Runs().FirstOrDefault(r=>r.State=="open")??store.CreateRun($"桌面采集 {DateTime.Now:MM-dd HH:mm}");
            if(id==1) scroll.Single(run.Id,store.GetRegion());
            if(id==2) scroll.Start(new(run.Id,store.GetRegion()),waitForFocus:false);
        }
        catch(Exception ex) { log.LogWarning(ex,"Hotkey action failed: {Message}",ex.Message); }
    });
    public Task StopAsync(CancellationToken token)
    {
        if(window is { IsDisposed:false,IsHandleCreated:true }) window.BeginInvoke((Action)window.Close);
        thread?.Join(2000); return Task.CompletedTask;
    }
    private sealed class HotkeyWindow(Action<int> dispatch,ILogger log) : Form
    {
        [DllImport("user32.dll")] private static extern bool RegisterHotKey(nint window,int id,uint mods,uint key);
        [DllImport("user32.dll")] private static extern bool UnregisterHotKey(nint window,int id);
        protected override void SetVisibleCore(bool value) => base.SetVisibleCore(false);
        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            var keys=new uint[]{0x53,0x57,0x51,0x52};
            for(var i=0;i<keys.Length;i++)
                if(!RegisterHotKey(Handle,i+1,0x4003,keys[i])) log.LogWarning("Hotkey Ctrl+Alt+{Key} is already in use",(char)keys[i]);
        }
        protected override void WndProc(ref Message m)
        { if(m.Msg==0x0312) dispatch((int)m.WParam); base.WndProc(ref m); }
        protected override void OnHandleDestroyed(EventArgs e)
        { for(var id=1;id<=4;id++) UnregisterHotKey(Handle,id); base.OnHandleDestroyed(e); }
    }
}
