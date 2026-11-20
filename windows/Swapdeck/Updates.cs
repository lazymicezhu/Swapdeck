using System.Net;
using System.Reflection;
using System.Security.Cryptography;
using Velopack;
namespace Swapdeck;

public sealed class Updates
{
    const string Feed = "https://github.com/lazymicezhu/Swapdeck/releases/download/windows-stable/";
    const string Index = "releases.win-x64.json";
    readonly HttpClient http = new() { Timeout = TimeSpan.FromMinutes(10) };
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
            using var response = await http.GetAsync(Feed + Index);
            if (response.StatusCode == HttpStatusCode.NotFound) return "Windows 通道尚未发布更新";
            response.EnsureSuccessStatusCode();
            var manifest = await response.Content.ReadAsByteArrayAsync();
            Verify(manifest, await http.GetByteArrayAsync(Feed + Index + ".sig"));
            Directory.CreateDirectory(temp); Files.Write(Path.Combine(temp, Index), manifest);
            var manager = new UpdateManager(temp, new UpdateOptions { ExplicitChannel = "win-x64", MaximumDeltasBeforeFallback = 0 });
            if (!manager.IsInstalled) return "请从 Windows 安装包启动以启用自动更新";
            var update = await manager.CheckForUpdatesAsync(); if (update == null) return "已是最新版本";
            var asset = update.TargetFullRelease;
            if (!confirm("更新至 " + asset.Version + "？\n\n" + asset.NotesMarkdown)) return "已取消更新";
            if (Path.GetFileName(asset.FileName) != asset.FileName || !asset.FileName.EndsWith("-full.nupkg")) throw new InvalidDataException("更新包名称异常。");
            var path = Path.Combine(temp, asset.FileName);
            using (var source = await http.GetStreamAsync(Feed + Uri.EscapeDataString(asset.FileName)))
            using (var file = File.Create(path)) await source.CopyToAsync(file);
            using (var file = File.OpenRead(path))
            {
                if (!Convert.ToHexString(SHA256.HashData(file)).Equals(asset.SHA256, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("更新包校验失败。");
            }
            await manager.DownloadUpdatesAsync(update); manager.ApplyUpdatesAndRestart(asset); return "正在重启";
        }
        finally { checking = false; if (Directory.Exists(temp)) Directory.Delete(temp, true); }
    }
}
