using Tomlyn.Syntax;
using System.Text;
using System.Text.RegularExpressions;
namespace Swapdeck;

public static class Endpoint
{
    public static Uri Root(string raw)
    {
        if (!Uri.TryCreate(raw.Trim(), UriKind.Absolute, out var u) || (u.Scheme != "https" && !(u.Scheme == "http" && u.IsLoopback)) ||
           u.UserInfo != "" || u.Query != "" || u.Fragment != "") throw new InvalidDataException("请输入有效的 HTTPS 中转地址。");
        var path = Regex.Replace(u.AbsolutePath.TrimEnd('/'), "/v1(?:/messages|/responses|/usage)?$", "");
        return new UriBuilder(u) { Path = path.TrimEnd('/') + "/" }.Uri;
    }
    public static bool ClientOnly(Uri uri)
    {
        var host = uri.IdnHost.TrimEnd('.').ToLowerInvariant();
        return host == "akko.gocode.de5.net" || host.EndsWith(".akko.gocode.de5.net");
    }
}
public static class TopLevelToml
{
    static KeyValueSyntax? Find(string text, string key)
    {
        var doc = Tomlyn.Toml.Parse(text);
        if (doc.HasErrors) throw new InvalidDataException("Codex 的 config.toml 格式有误，请检查后重试。");
        return doc.KeyValues.FirstOrDefault(entry => entry.Key != null && !entry.Key.DotKeys.Any() && entry.Key.Key switch
        {
            BareKeySyntax bare => bare.Key?.Text == key,
            StringValueSyntax quoted => quoted.Value == key,
            _ => false
        });
    }

    public static string? Get(string text, string key) => (Find(text, key)?.Value as StringValueSyntax)?.Value;

    public static string Set(string text, string key, string? value)
    {
        var entry = Find(text, key);
        string newline = text.Contains("\r\n") ? "\r\n" : "\n";
        if (entry?.Value == null)
            return value == null ? text : key + " = " + JsonSerializer.Serialize(value) + newline + text;
        var span = entry.Value.Span;
        if (value != null)
            return text.Remove(span.Offset, span.Length).Insert(span.Offset, JsonSerializer.Serialize(value));
        int start = entry.Key!.Span.Offset;
        int end = span.Offset + span.Length;
        if (text.AsSpan(end).StartsWith(newline)) end += newline.Length;
        return text.Remove(start, end - start);
    }
}
public sealed class Clients(Paths paths, Accounts accounts)
{
    public string Library => accounts.Library ?? paths.Library;
    string Meta => Path.Combine(Library, "_meta.json");
    public Dictionary<string, byte[]?> Claude(Profile p)
    {
        var changes = new Dictionary<string, byte[]?>();
        if (File.Exists(Meta))
        {
            var meta = Files.Object(Meta); var id = p.Id.ToString(); var dest = Path.Combine(Library, id + ".json");
            var entry = Files.Object(dest);
            if (!File.Exists(dest) && Guid.TryParse(meta["appliedId"]?.ToString(), out var last)) entry = Files.Object(Path.Combine(Library, last + ".json"));
            entry["inferenceProvider"] = "gateway"; entry["inferenceGatewayBaseUrl"] = p.Url.TrimEnd('/');
            entry["inferenceGatewayApiKey"] = p.Secret; entry["inferenceGatewayAuthScheme"] = "bearer"; entry.Remove("inferenceCredentialKind");
            var entries = meta["entries"]?.AsArray() ?? new JsonArray(); if (meta["entries"] == null) meta["entries"] = entries;
            var item = entries.OfType<JsonObject>().FirstOrDefault(x => x["id"]?.ToString() == id);
            if (item == null) { item = new JsonObject { ["id"] = id }; entries.Add(item); }
            item["name"] = "切号 · " + p.Name; meta["appliedId"] = id;
            changes[dest] = Files.Json(entry); changes[Meta] = Files.Json(meta);
        }
        if (accounts.SyncCli)
        {
            var json = Files.Object(paths.Settings); var env = json["env"]?.AsObject() ?? new();
            if (json["env"] == null) json["env"] = env;
            env["ANTHROPIC_BASE_URL"] = p.Url.TrimEnd('/'); env["ANTHROPIC_AUTH_TOKEN"] = p.Secret;
            var baseline = Path.Combine(paths.Data, "cli-traffic.bin");
            if (!File.Exists(baseline)) changes[baseline] = Files.Protect(Files.Json(env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"]?.ToString() ?? ""));
            if (Endpoint.ClientOnly(Endpoint.Root(p.Url))) env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1";
            else if (File.Exists(baseline))
            {
                var old = JsonSerializer.Deserialize<string>(Files.Unlock(File.ReadAllBytes(baseline)));
                if (string.IsNullOrEmpty(old)) env.Remove("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"); else env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = old;
            }
            changes[paths.Settings] = Files.Json(json);
        }
        if (changes.Count == 0) throw new InvalidOperationException("请在 Claude 开启第三方模式或启用同步 Claude Code。");
        return changes;
    }
    public string Toml => File.Exists(paths.Config) ? File.ReadAllText(paths.Config) : "";
    static readonly Uri ChatGpt = new("https://chatgpt.com/backend-api/codex");
    public Dictionary<string, byte[]?> Codex(Profile? p, string? url)
    {
        var config = Toml;
        var endpoint = url == null ? ChatGpt : new Uri(url);
        config = ProviderCredentials.Align(config,endpoint,p is {Official:false}?p.Secret:null);
        url = ProviderCredentials.WebSocket(endpoint).AbsoluteUri;
        if (TopLevelToml.Get(config, "model_provider") is { } provider && provider != "openai")
            config = TopLevelToml.Set(config, "model_provider", "openai");
        var auth = p == null ? null : p.Official ? Encoding.UTF8.GetBytes(p.Secret) : Files.Json(new { auth_mode = "apikey", OPENAI_API_KEY = p.Secret });
        return new() { [paths.Auth] = auth, [paths.Config] = Encoding.UTF8.GetBytes(TopLevelToml.Set(config, "openai_base_url", url)) };
    }
    public Guid? Active(string tab)
    {
        if (tab == "Claude")
        {
            if (File.Exists(Meta) && Guid.TryParse(Files.Object(Meta)["appliedId"]?.ToString(), out var id)) return id;
            var env = Files.Object(paths.Settings)["env"];
            return accounts.Cards.FirstOrDefault(p => p.Client == tab && p.Url.TrimEnd('/') == env?["ANTHROPIC_BASE_URL"]?.ToString()?.TrimEnd('/') && p.Secret == env?["ANTHROPIC_AUTH_TOKEN"]?.ToString())?.Id;
        }
        if (TopLevelToml.Get(Toml, "model_provider") is { } provider && provider != "openai") return null;
        var saved = SavedLogin();
        if (saved == null) return null;
        var profile = accounts.Cards.First(p => p.Id == saved);
        var config = Toml;
        var address = TopLevelToml.Get(config, "openai_base_url");
        if (profile.Official) return address == ProviderCredentials.WebSocket(ChatGpt).AbsoluteUri ? saved : null;
        if (!Uri.TryCreate(address, UriKind.Absolute, out var url)) return null;
        var expected = new Uri(Endpoint.Root(profile.Url), "v1");
        if (url != ProviderCredentials.WebSocket(expected)) return null;
        try { return ProviderCredentials.Align(config, expected, profile.Secret) == config ? saved : null; }
        catch (InvalidDataException) { return null; }
    }
    public Guid? SavedLogin()
    {
        var auth = Files.Object(paths.Auth);
        return accounts.Cards.FirstOrDefault(p => p.Client == "Codex" && (p.Official ? AccountId(JsonNode.Parse(p.Secret)) is { } aid && aid == AccountId(auth) : p.Secret == auth["OPENAI_API_KEY"]?.ToString()))?.Id;
    }
    static string? AccountId(JsonNode? obj) => obj?["tokens"]?["account_id"]?.ToString();
    public bool RememberLogin()
    {
        var auth = Files.Object(paths.Auth); if (AccountId(auth) is not { } id || auth["tokens"]?["access_token"] == null) return false;
        var existing = accounts.Cards.FindIndex(p => p.Official && AccountId(JsonNode.Parse(p.Secret)) == id);
        var secret = auth.ToJsonString();
        if (existing >= 0) { var p = accounts.Cards[existing]; if (p.Secret == secret) return false; accounts.Cards[existing] = p with { Secret = secret }; }
        else accounts.Cards.Add(new(Guid.NewGuid(), "Codex", "ChatGPT · " + id[^Math.Min(6, id.Length)..], "", secret, true));
        return true;
    }
}
