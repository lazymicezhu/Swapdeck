using Tomlyn.Syntax;

namespace Swapdeck;

// Resumed threads can still select their original provider by its case-sensitive id.
static class ProviderCredentials
{
    static string KeyPart(BareKeyOrStringValueSyntax? key) => key switch
    {
        BareKeySyntax bare => bare.Key!.Text!,
        StringValueSyntax quoted => quoted.Value!,
        _ => throw new InvalidDataException("无法读取 Codex 配置键。")
    };

    static string[] Parts(KeySyntax key) => [KeyPart(key.Key), .. key.DotKeys.Select(k => KeyPart(k.Key))];

    static IEnumerable<(string[] Path, ValueSyntax Value)> Fields(string[] prefix, IEnumerable<KeyValueSyntax> items)
    {
        foreach (var item in items)
        {
            string[] path = [.. prefix, .. Parts(item.Key!)];
            if (item.Value is InlineTableSyntax table)
            {
                foreach (var field in Fields(path, table.Items.Select(i => i.KeyValue!))) yield return field;
            }
            else if (item.Value != null) yield return (path, item.Value);
        }
    }

    public static Uri WebSocket(Uri endpoint) => new UriBuilder(endpoint) {
        Scheme = endpoint.Scheme == "http" && endpoint.IsLoopback ? "ws" : "wss",
        Port = endpoint.IsDefaultPort ? -1 : endpoint.Port
    }.Uri;

    public static string Align(string text, Uri endpoint, string? secret)
    {
        var doc = Tomlyn.Toml.Parse(text);
        if (doc.HasErrors) throw new InvalidDataException("Codex 配置格式有误。");
        var fields = Fields([], doc.KeyValues).Concat(doc.Tables.OfType<TableSyntax>()
            .SelectMany(t => Fields(Parts(t.Name!), t.Items)));
        var edits = new List<(int Offset, int Length, string Value)>();
        var socket = WebSocket(endpoint);
        foreach (var provider in fields.Where(f => f.Path.Length >= 3 && f.Path[0] == "model_providers").GroupBy(f => f.Path[1]))
        {
            var address = provider.FirstOrDefault(f => f.Path is [_, _, "base_url"]).Value as StringValueSyntax;
            if (address == null || !Uri.TryCreate(address.Value?.TrimEnd('/'), UriKind.Absolute, out var url) || (url != endpoint && url != socket)) continue;
            if (url != socket) edits.Add((address.Span.Offset,address.Span.Length,JsonSerializer.Serialize(socket.AbsoluteUri)));
            var support = provider.FirstOrDefault(f=>f.Path is [_, _, "supports_websockets"]).Value;
            if (support == null) {
                var entry = (KeyValueSyntax)address.Parent!;
                var key = entry.Key!;
                var last = key.DotKeys.LastOrDefault()?.Key ?? key.Key!;
                var prefix = text[key.Span.Offset..last.Span.Offset];
                var inline = entry.Parent is InlineTableItemSyntax || entry.Parent?.Parent is InlineTableItemSyntax;
                edits.Add((key.Span.Offset,0,prefix+"supports_websockets = true"+(inline?", ":text.Contains("\r\n")?"\r\n":"\n")));
            } else if (text.Substring(support.Span.Offset,support.Span.Length)!="true")
                edits.Add((support.Span.Offset,support.Span.Length,"true"));
            foreach (var (path, node) in provider)
            {
                if (path is [_, _, "env_key"] or [_, _, "auth", ..] ||
                    path is [_, _, "env_http_headers", var h] && IsAuthHeader(h))
                    throw new InvalidDataException($"同站点提供方 {provider.Key} 使用外部凭据，请先在 Codex 配置中解除该覆盖。");
                string? value = path switch
                {
                    [_, _, "experimental_bearer_token"] => secret,
                    [_, _, "http_headers", var header] when header.Equals("Authorization", StringComparison.OrdinalIgnoreCase) => "Bearer " + secret,
                    [_, _, "http_headers", var header] when IsAuthHeader(header) => secret,
                    _ => null
                };
                if (secret != null && value != null && (node as StringValueSyntax)?.Value != value) edits.Add((node.Span.Offset,node.Span.Length,JsonSerializer.Serialize(value)));
            }
        }
        foreach (var edit in edits.OrderByDescending(e => e.Offset))
            text = text.Remove(edit.Offset, edit.Length).Insert(edit.Offset, edit.Value);
        return text;
    }

    static bool IsAuthHeader(string key) => key.Equals("Authorization", StringComparison.OrdinalIgnoreCase)
        || key.Equals("x-api-key", StringComparison.OrdinalIgnoreCase) || key.Equals("api-key", StringComparison.OrdinalIgnoreCase);
}
