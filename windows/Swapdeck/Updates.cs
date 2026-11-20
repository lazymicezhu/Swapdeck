using System.Net;
using System.Reflection;
using System.Security.Cryptography;
using Velopack;
namespace Swapdeck;

public sealed class Updates
{
    const string Releases = "https://api.github.com/repos/lazymicezhu/Swapdeck/releases";
    const string Download = "https://github.com/lazymicezhu/Swapdeck/releases/download/";
    readonly HttpClient http = new() { Timeout = TimeSpan.FromMinutes(10), DefaultRequestHeaders = { { "User-Agent", "Swapdeck-Windows" } } };

    async Task<Version?> Latest()
    {
        Version? latest = null;
        for (int page = 1; ; page++)
        {
            var json = await http.GetStringAsync($"{Releases}?per_page=100&page={page}");
            var releases = JsonNode.Parse(json)!.AsArray();
            foreach (var release in releases)
            {
                string tag = release?["tag_name"]?.ToString() ?? "";
                const string prefix = "windows-v";
                if ((bool?)release?["draft"] == true || !tag.StartsWith(prefix,StringComparison.Ordinal) ||
                    !Version.TryParse(tag[prefix.Length..], out var v) || tag != prefix + v ||
                    release?["assets"] is not JsonArray assets || !assets.Any(a=>a?["name"]?.ToString()==FileName(v))) continue;
                if (latest == null || v > latest) latest = v;
            }
            if (releases.Count < 100) return latest;
        }
    }
    static string FileName(Version version) => $"Swapdeck-{version}-win-x64-Setup.exe";
    bool checking;
    public static void Verify(byte[] data, byte[] sig)
    {
        using var rsa = RSA.Create(); using var stream = typeof(Updates).Assembly.GetManifestResourceStream("Swapdeck.update-public.pem")!;
        using var reader = new StreamReader(stream); rsa.ImportFromPem(reader.ReadToEnd());
        if (!rsa.VerifyData(data, sig, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1)) throw new InvalidDataException("更新签名验证失败。");
    }
    public async Task<string> Check(Func<string, bool> confirm)
    {
        if (checking) return "正在检查更新"; checking = true;
        var temp = Path.Combine(Path.GetTempPath(), "Swapdeck-update-" + Guid.NewGuid().ToString("N"));
        try
        {
            var version = await Latest();
            if (version == null) return "Windows 通道尚未发布更新";
            var current = Version.Parse(typeof(Updates).Assembly.GetName().Version!.ToString(3));
            if (version <= current) return "已是最新版本";
            Directory.CreateDirectory(temp);
            var manager = new UpdateManager(temp, new UpdateOptions { ExplicitChannel = "win-x64", MaximumDeltasBeforeFallback = 0 });
            if (!manager.IsInstalled) return "请从 Windows 安装包启动以启用自动更新";
            if (!confirm($"下载并安装 Windows {version}？")) return "已取消更新";
            string setup = Path.Combine(temp, FileName(version));
            using (var source = await http.GetStreamAsync($"{Download}windows-v{version}/{FileName(version)}"))
            using (var file = File.Create(setup)) await source.CopyToAsync(file);
            await Task.Run(()=>BundledUpdate.Extract(setup,temp,version));
            var update = await manager.CheckForUpdatesAsync();
            if (update == null) return "已是最新版本";
            var asset = update.TargetFullRelease;
            await manager.DownloadUpdatesAsync(update); manager.ApplyUpdatesAndRestart(asset); return "正在重启";
        }
        finally { checking = false; if (Directory.Exists(temp)) Directory.Delete(temp, true); }
    }
}
