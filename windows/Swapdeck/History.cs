namespace Swapdeck;

public sealed record DayUsage(long Input, long Cached, long Output, double Cost, long Written = 0)
{
    public static DayUsage operator +(DayUsage a, DayUsage b) => new(a.Input + b.Input, a.Cached + b.Cached, a.Output + b.Output, a.Cost + b.Cost, a.Written + b.Written);
}
public sealed class History
{
    public Dictionary<(string Client, DateOnly Date, string Model), DayUsage> Rows { get; } = [];
    public Dictionary<string, Dictionary<DateOnly, double>> Accounts { get; } = [];
    static readonly JsonObject prices = Files.Object(Path.Combine(AppContext.BaseDirectory, "prices.json"));
    static long N(JsonNode? obj, string key) => (long?)obj?[key] ?? 0;
    public static History Scan(Paths paths)
    {
        var history = new History(); var seen = new HashSet<string>(); var since = DateTime.MinValue; var owners = ThreadOwners.Read(paths.Codex);
        foreach (var (client, root) in new[] { ("Claude", Path.Combine(paths.Home, ".claude", "projects")), ("Codex", Path.Combine(paths.Codex, "sessions")), ("Codex", Path.Combine(paths.Codex, "archived_sessions")) })
        {
            foreach (var file in Activity.Logs(root, since))
            {
                if (client == "Codex" && !seen.Add(Path.GetFileName(file))) continue;
                string model = "gpt-5", tier = ""; long previous = -1; bool replay = false;
                try
                {
                    using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                    using var reader = new StreamReader(stream);
                    while (reader.ReadLine() is { } line)
                    {
                        if (!line.Contains("\"usage\"") && !line.Contains("token_count") && !line.Contains("turn_context") && !line.Contains("session_meta") && !line.Contains("task_started") && !line.Contains("thread_settings_applied")) continue;
                        JsonNode? obj; try { obj = JsonNode.Parse(line); } catch (JsonException) { continue; }
                        if (!DateTimeOffset.TryParse(obj?["timestamp"]?.ToString(), out var time)) continue;
                        long input, cached, output, write = 0;
                        if (client == "Claude")
                        {
                            var msg = obj?["message"]; var u = msg?["usage"]; if (u == null || obj?["type"]?.ToString() != "assistant") continue;
                            if (msg?["id"] is { } mid && !seen.Add(mid.ToString())) continue;
                            model = msg?["model"]?.ToString() ?? "未知"; input = N(u, "input_tokens"); cached = N(u, "cache_read_input_tokens"); output = N(u, "output_tokens"); write = N(u, "cache_creation_input_tokens");
                        }
                        else
                        {
                            var p = obj?["payload"]; var type = obj?["type"]?.ToString();
                            if (type == "session_meta") { replay = p?["forked_from_id"] != null || p?["parent_thread_id"] != null; continue; }
                            if (type == "turn_context") { model = p?["model"]?.ToString() ?? model; continue; }
                            if (p?["type"]?.ToString() == "thread_settings_applied") { tier = p["thread_settings"]?["service_tier"]?.ToString() ?? ""; continue; }
                            if (p?["type"]?.ToString() == "task_started") { replay = false; continue; }
                            if (p?["type"]?.ToString() != "token_count") continue;
                            var info = p["info"]; var u = info?["last_token_usage"]; if (u == null) continue;
                            long total = N(info?["total_token_usage"], "total_tokens"); if (total != 0 && total == previous) continue; previous = total;
                            if (replay) continue;
                            input = N(u, "input_tokens"); cached = Math.Min(input, N(u, "cached_input_tokens")); input -= cached; output = N(u, "output_tokens");
                        }
                        var day = DateOnly.FromDateTime(time.LocalDateTime); if (day < DateOnly.FromDateTime(since)) continue;
                        var row = prices[model]; double Rate(string key)
                        {
                            var size = input + cached > 272000 && row?[key + "_above_272k_tokens"] != null ? "_above_272k_tokens" : "";
                            var suffix = tier == "ultrafast" ? "_ultrafast" : tier is "fast" or "priority" ? "_priority" : "";
                            var standard = (double?)row?[key + size] ?? 0;
                            return (double?)row?[key + size + suffix] ?? standard * (suffix == "" ? 1 : 2);
                        }
                        double cost = model == "codex-auto-review" && time >= new DateTimeOffset(2026, 10, 6, 0, 0, 0, TimeSpan.Zero) ? 0 :
                            input * Rate("input_cost_per_token") + cached * Rate("cache_read_input_token_cost") + output * Rate("output_cost_per_token") + write * Rate("cache_creation_input_token_cost");
                        var k = (client, day, model);
                        history.Rows[k] = history.Rows.GetValueOrDefault(k, new(0, 0, 0, 0)) + new DayUsage(input, cached, output, cost, write);
                        if (client == "Codex" && owners.TryGetValue(Path.GetFileName(file), out var owner)) {
                            if (!history.Accounts.TryGetValue(owner, out var days)) history.Accounts[owner] = days = [];
                            days[day] = days.GetValueOrDefault(day) + cost;
                        }
                    }
                }
                catch (IOException) { continue; }
            }
        }
        return history;
    }
}

