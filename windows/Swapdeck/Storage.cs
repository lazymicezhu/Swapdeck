global using System.IO;
global using System.Net.Http;
global using System.Text.Json;
global using System.Text.Json.Nodes;
using System.Security.Cryptography;
using System.Text;

namespace Swapdeck;

public sealed record Paths(string Home, string Codex, string Data, string Library)
{
    public static Paths Current()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var roaming = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var library = Path.Combine(roaming, "Claude-3p", "configLibrary");
        return new(home, Environment.GetEnvironmentVariable("CODEX_HOME") ?? Path.Combine(home, ".codex"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Swapdeck", "UserData"), library);
    }
    public string Settings => Path.Combine(Home, ".claude", "settings.json");
    public string Auth => Path.Combine(Codex, "auth.json");
    public string Config => Path.Combine(Codex, "config.toml");
}

public sealed record Profile(Guid Id, string Client, string Name, string Url, string Secret, bool Official = false, decimal Ratio = 1, string? SiteAccess = null, int? SiteKey = null);
public sealed class Accounts
{
    public List<Profile> Cards { get; set; } = [];
    public double? Left { get; set; }
    public double? Top { get; set; }
    public bool AutoUpdate { get; set; } = true;
    public bool Topmost { get; set; }
    public bool SyncCli { get; set; } = true;
    public string Tab { get; set; } = "Claude";
    public string? Library { get; set; }
    public bool Restart { get; set; } = true;
}
public static class Files
{
    public static JsonObject Object(string path) => File.Exists(path) ?
        JsonNode.Parse(File.ReadAllText(path), documentOptions: new() { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true })!.AsObject() : new();
    public static byte[] Json(object value) => JsonSerializer.SerializeToUtf8Bytes(value, new JsonSerializerOptions { WriteIndented = true });
    public static void Write(string path, byte[]? bytes)
    {
        if (bytes is null) { File.Delete(path); return; }
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var file = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { file.Write(bytes); file.Flush(true); }
            File.Move(temp, path, true);
        }
        finally { File.Delete(temp); }
    }
    public static byte[]? Read(string path) => File.Exists(path) ? File.ReadAllBytes(path) : null;
    public static byte[] Protect(byte[] data) => ProtectedData.Protect(data, null, DataProtectionScope.CurrentUser);
    public static byte[] Unlock(byte[] data) => ProtectedData.Unprotect(data, null, DataProtectionScope.CurrentUser);
}
public sealed class Vault(Paths paths)
{
    string FileName => Path.Combine(paths.Data, "profiles.bin");
    public Accounts Load() => Files.Read(FileName) is { } bytes ? JsonSerializer.Deserialize<Accounts>(Files.Unlock(bytes))! : new();
    public void Save(Accounts accounts) => Files.Write(FileName, Files.Protect(Files.Json(accounts)));
}
// Write-ahead journal covers interrupted multi-file switches. Single-instance UI serializes writers.
public sealed class SwitchFiles(Paths paths)
{
    string Journal => Path.Combine(paths.Data, "pending.bin");
    public void Recover()
    {
        if (Files.Read(Journal) is not { } bytes) return;
        var before = JsonSerializer.Deserialize<Dictionary<string, byte[]?>>(Files.Unlock(bytes))!;
        foreach (var (path, data) in before) Files.Write(path, data);
        File.Delete(Journal);
    }
    public void Commit(Dictionary<string, byte[]?> changes)
    {
        Recover();
        var before = changes.Keys.ToDictionary(p => p, Files.Read);
        var backup = Path.Combine(paths.Data, "initial-backup.bin");
        var original = Files.Read(backup) is { } saved ? JsonSerializer.Deserialize<Dictionary<string, byte[]?>>(Files.Unlock(saved))! : new();
        foreach (var (p, b) in before) original.TryAdd(p, b);
        Files.Write(backup, Files.Protect(Files.Json(original)));
        Files.Write(Journal, Files.Protect(Files.Json(before)));
        try { foreach (var (p, b) in changes) Files.Write(p, b); File.Delete(Journal); }
        catch { Recover(); throw; }
    }
}

