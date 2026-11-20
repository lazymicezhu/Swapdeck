using System.ComponentModel;
using System.Diagnostics;
using System.Xml.Linq;


namespace Swapdeck;

public sealed class DesktopRestart
{
    private readonly string executable;
    private readonly string? appId;
    private readonly int oldPid;

    private DesktopRestart(Process process, string path)
    {
        executable = path;
        oldPid = process.Id;
        appId = PackageEntry(path);
    }

    internal static string? PackageEntry(string path)
    {
        for (var directory = Directory.GetParent(path); directory != null; directory = directory.Parent)
        {
            if (!string.Equals(directory.Parent?.Name, "WindowsApps", StringComparison.OrdinalIgnoreCase)) continue;
            var manifest = Path.Combine(directory.FullName, "AppxManifest.xml");
            if (!File.Exists(manifest)) return null;
            var xml = XDocument.Load(manifest);
            var app = xml.Descendants().FirstOrDefault(e => e.Name.LocalName == "Application" &&
                string.Equals(((string?)e.Attribute("Executable"))?.Replace('/', Path.DirectorySeparatorChar),
                    Path.GetRelativePath(directory.FullName, path), StringComparison.OrdinalIgnoreCase));
            var identity = xml.Root?.Elements().FirstOrDefault(e => e.Name.LocalName == "Identity");
            string? name = (string?)identity?.Attribute("Name"), id = (string?)app?.Attribute("Id");
            if (name == null || id == null) return null;
            return name + "_" + directory.Name.Split('_')[^1] + "!" + id;
        }
        return null;
    }
    public static bool IsDesktopPath(string client, string path)
    {
        string? folder = Path.GetDirectoryName(path);
        string filename = Path.GetFileNameWithoutExtension(path);
        if (string.Equals(Path.GetFileName(folder), "resources", StringComparison.OrdinalIgnoreCase))
            return false;
        if (string.Equals(filename, client, StringComparison.OrdinalIgnoreCase))
            return true;
        // The Store edition of Codex can ship its GUI as ChatGPT.exe.
        string? package = folder == null ? null : Path.GetFileName(Path.GetDirectoryName(folder));
        return client == "Codex" && filename.Equals("ChatGPT", StringComparison.OrdinalIgnoreCase)
            && string.Equals(Path.GetFileName(folder), "app", StringComparison.OrdinalIgnoreCase)
            && package?.StartsWith("OpenAI.Codex_", StringComparison.OrdinalIgnoreCase) == true;
    }

    // CLI binaries can have the same filename as the Electron GUI. Only consider GUI images.
    private static bool IsWindowedImage(string path)
    {
        using var stream = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        using var pe = new System.Reflection.PortableExecutable.PEReader(stream);
        return pe.PEHeaders.PEHeader?.Subsystem == System.Reflection.PortableExecutable.Subsystem.WindowsGui;
    }

    public static async Task<DesktopRestart?> Close(string client, Func<bool> busy)
    {
        using var current = Process.GetCurrentProcess();
        string[] names = client == "Codex" ? ["Codex", "ChatGPT"] : [client];
        var candidates = names.SelectMany(Process.GetProcessesByName).ToArray();
        try
        {
            var targets = new List<Process>();
            string? executable = null;
            foreach (var process in candidates)
            {
                if (process.HasExited || process.SessionId != current.SessionId) continue;
                string? path;
                try { path = process.MainModule?.FileName; }
                catch (InvalidOperationException) when (process.HasExited) { continue; }
                if (path == null || !IsDesktopPath(client, path) || !IsWindowedImage(path)) continue;
                if (executable != null && !StringComparer.OrdinalIgnoreCase.Equals(executable, path))
                    throw new InvalidOperationException("检测到多个客户端安装正在运行，请关闭多余的实例。");
                executable = path;
                targets.Add(process);
            }
            if (executable == null) return null;
            var root = targets.OrderByDescending(p => p.MainWindowHandle != IntPtr.Zero).First();
            var restart = new DesktopRestart(root, executable);
            if (busy()) throw new InvalidOperationException("客户端正在调用中，请在结束后切换。");
            if (!root.HasExited && root.MainWindowHandle != IntPtr.Zero)
            {
                try { root.CloseMainWindow(); }
                catch (InvalidOperationException) when (root.HasExited) { }
                await WaitForExit(targets, TimeSpan.FromSeconds(4));
            }
            if (targets.Any(p => !p.HasExited))
            {
                if (busy()) throw new InvalidOperationException("客户端正在调用中，已取消强制退出。");
                foreach (var process in targets)
                {
                    if (process.HasExited) continue;
                    try { process.Kill(); }
                    catch (InvalidOperationException) when (process.HasExited) { }
                }
                if (!await WaitForExit(targets, TimeSpan.FromSeconds(8)))
                    throw new InvalidOperationException(client + " 仍在运行，切换已取消。");
            }
            return restart;
        }
        finally { foreach (var process in candidates) process.Dispose(); }
    }

    private static async Task<bool> WaitForExit(IEnumerable<Process> targets, TimeSpan timeout)
    {
        using var limit = new CancellationTokenSource(timeout);
        try { await Task.WhenAll(targets.Select(p => p.WaitForExitAsync(limit.Token))); return true; }
        catch (OperationCanceledException) { return false; }
    }
    public async Task Reopen()
    {
        try
        {
            var target = string.IsNullOrEmpty(appId) ? executable : @"shell:AppsFolder\" + appId;
            using var launched = Process.Start(new ProcessStartInfo(target) { UseShellExecute = appId != null });
            var elapsed = Stopwatch.StartNew();
            while (elapsed.Elapsed < TimeSpan.FromSeconds(20))
            {
                var processes = Process.GetProcessesByName(Path.GetFileNameWithoutExtension(executable));
                try
                {
                    foreach (var process in processes)
                    {
                        if (process.Id == oldPid || process.MainWindowHandle == IntPtr.Zero) continue;
                        try
                        {
                            if (string.Equals(process.MainModule?.FileName, executable, StringComparison.OrdinalIgnoreCase)) return;
                        }
                        catch (InvalidOperationException) when (process.HasExited) { }
                    }
                }
                finally { foreach (var process in processes) process.Dispose(); }
                await Task.Delay(250);
            }
        }
        catch (Win32Exception ex) { throw new InvalidOperationException("客户端重新启动失败，请从开始菜单打开。", ex); }
        throw new InvalidOperationException("客户端已退出，尚未检测到重新打开的窗口。请从开始菜单打开。");
    }
}
