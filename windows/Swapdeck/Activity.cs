using System.Diagnostics;
namespace Swapdeck;

public static class Activity
{
    public static IEnumerable<string> Logs(string root, DateTime since) => Directory.Exists(root) ?
        Directory.EnumerateFiles(root, "*.jsonl", new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true })
        .Where(p => File.GetLastWriteTime(p) >= since) : [];
    public static bool Busy(Paths paths, string name)
    {
        bool codex = name == "Codex";
        var root = codex ? Path.Combine(paths.Codex, "sessions") : Path.Combine(paths.Home, ".claude", "projects");
        foreach (var path in Logs(root, DateTime.Now.AddHours(-6)))
        {
            using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            file.Position = Math.Max(0, file.Length - 262144); using var reader = new StreamReader(file);
            var lines = reader.ReadToEnd().Split('\n'); bool decided = false;
            foreach (var line in lines.Reverse())
            {
                if (string.IsNullOrWhiteSpace(line)) continue;
                JsonNode? j; try { j = JsonNode.Parse(line); } catch (JsonException) { continue; }
                if (codex && j?["type"]?.ToString() == "event_msg")
                {
                    var type = j["payload"]?["type"]?.ToString();
                    if (type == "task_started") return true;
                    if (type is "task_complete" or "turn_aborted") { decided = true; break; }
                }
                else if (!codex)
                {
                    var type = j?["type"]?.ToString();
                    if (type == "assistant")
                    {
                        if (j?["message"]?["stop_reason"]?.ToString() is not ("end_turn" or "stop_sequence" or "max_tokens" or "refusal")) return true;
                        decided = true; break;
                    }
                    if (type == "user" && (bool?)j?["isMeta"] != true) return true;
                }
            }
            if (!decided && File.GetLastWriteTime(path) > DateTime.Now.AddMinutes(-1)) return true;
        }
        return false;
    }
}