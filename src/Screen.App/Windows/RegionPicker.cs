using System.Drawing;
using System.Windows.Forms;

namespace Screen.App.Windows;

public sealed class RegionPicker : IRegionPicker
{
    private readonly SemaphoreSlim gate=new(1,1);
    public async Task<Region?> PickAsync()
    {
        await gate.WaitAsync();
        try
        {
            var completion=new TaskCompletionSource<Region?>(TaskCreationOptions.RunContinuationsAsynchronously);
            var thread=new Thread(()=> {
                try { using var form=new SelectionForm(); form.ShowDialog(); completion.SetResult(form.Selection); }
                catch(Exception ex) { completion.SetException(ex); }
            });
            thread.SetApartmentState(ApartmentState.STA); thread.IsBackground=true; thread.Start();
            return await completion.Task;
        }
        finally { gate.Release(); }
    }
    private sealed class SelectionForm : Form
    {
        private Point? start; private Rectangle rectangle;
        public Region? Selection { get; private set; }
        public SelectionForm()
        {
            FormBorderStyle=FormBorderStyle.None; StartPosition=FormStartPosition.Manual;
            Bounds=SystemInformation.VirtualScreen; BackColor=Color.Black; Opacity=0.55;
            TopMost=true; ShowInTaskbar=false; KeyPreview=true; Cursor=Cursors.Cross; DoubleBuffered=true;
            KeyDown+=(_,e)=> { if(e.KeyCode==Keys.Escape) Close(); };
            MouseDown+=(_,e)=> { if(e.Button==MouseButtons.Left) start=e.Location; };
            MouseMove+=(_,e)=> {
                if(start is not { } p) return;
                rectangle=new(Math.Min(p.X,e.X),Math.Min(p.Y,e.Y),Math.Abs(p.X-e.X),Math.Abs(p.Y-e.Y)); Invalidate();
            };
            MouseUp+=(_,e)=> {
                if(e.Button!=MouseButtons.Left) return;
                if(rectangle.Width>=40&&rectangle.Height>=40)
                    Selection=new(Left+rectangle.X,Top+rectangle.Y,rectangle.Width,rectangle.Height);
                Close();
            };
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e); using var font=new Font("Microsoft YaHei",14);
            e.Graphics.DrawString("拖动框选阅读区域 · 松开保存 · Esc 取消",font,Brushes.White,28,28);
            using var pen=new Pen(Color.FromArgb(93,224,176),3);
            if(rectangle.Width>0&&rectangle.Height>0) e.Graphics.DrawRectangle(pen,rectangle);
        }
    }
}
