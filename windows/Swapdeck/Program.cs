using System.Windows;
using Velopack;
namespace Swapdeck;

static class Program
{
    [STAThread]
    public static void Main(string[] args)
    {
        VelopackApp.Build().SetAutoApplyOnStartup(false).Run();
        using var single = new Mutex(true, @"Local\Swapdeck.Windows.1", out bool owner);
        using var wake = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\Swapdeck.Windows.Show.1");
        if (!owner) { wake.Set(); return; }
        try
        {
            var app = new Application(); var paths = Paths.Current(); new SwitchFiles(paths).Recover();
            var window = new MainWindow(paths);
            var registration = ThreadPool.RegisterWaitForSingleObject(wake, (_, _) => app.Dispatcher.BeginInvoke(() =>
            {
                window.Show(); window.WindowState = WindowState.Normal; window.Activate();
            }), null, Timeout.Infinite, false);
            try { app.Run(window); } finally { registration.Unregister(null); }
        }
        catch (Exception ex) { MessageBox.Show("切号无法启动。\n" + ex.Message, "Swapdeck"); }
    }
}
