using System.Net;
using System.Net.Http.Headers;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging;
namespace Swapdeck;

public sealed class RelayGuard(HttpMessageHandler inner) : DelegatingHandler(inner)
{
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage r, CancellationToken cancel)
    {
        var uri = r.RequestUri ?? throw new InvalidOperationException("缺少请求地址。");
        if (Endpoint.ClientOnly(uri) && !(r.Method == HttpMethod.Get && r.Content == null && uri.AbsoluteUri == AkkoUsage.AbsoluteUri))
            throw new InvalidOperationException("Akko 仅允许查询额度。");
        return base.SendAsync(r, cancel);
    }
    public static HttpClient Client() => new(new RelayGuard(new HttpClientHandler { AllowAutoRedirect = false })) { Timeout = Timeout.InfiniteTimeSpan };
    public static readonly Uri AkkoUsage = new("https://akko.gocode.de5.net/v1/usage");
}
public sealed record Meter(double Remaining, DateTimeOffset? Reset, double? Left = null);
public sealed record Reading(decimal? Balance = null, Meter? Five = null, Meter? Week = null, string? Plan = null, string? Credits = null, string? Note = null, Dictionary<DateOnly,decimal>? Daily = null);
public sealed class Balances(HttpClient http)
{
    async Task<JsonNode?> Get(Uri url, string token, string? account = null)
    {
        using var req = new HttpRequestMessage(HttpMethod.Get, url);
        req.Headers.Accept.Add(new("application/json"));
        req.Headers.Authorization = new("Bearer", token);
        if (account != null) req.Headers.Add("ChatGPT-Account-Id", account);
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
        using var response = await http.SendAsync(req, timeout.Token);
        if (response.StatusCode == HttpStatusCode.NotFound) return null;
        response.EnsureSuccessStatusCode();
        return JsonNode.Parse(await response.Content.ReadAsStringAsync(timeout.Token));
    }
    public async Task<Reading> Read(Profile p)
    {
        try
        {
            if (p.Official)
            {
                var tokens = JsonNode.Parse(p.Secret)!["tokens"]!;
                var data = await Get(new("https://chatgpt.com/backend-api/wham/usage"), tokens["access_token"]!.ToString(), tokens["account_id"]!.ToString());
                Meter? five = null, week = null;
                foreach (var name in new[] { "primary_window", "secondary_window" })
                {
                    var w = data?["rate_limit"]?[name]; if (w?["used_percent"] == null) continue;
                    var meter = new Meter(Math.Clamp(100 - (double)w["used_percent"]!, 0, 100), w["reset_at"] == null ? null : DateTimeOffset.FromUnixTimeSeconds((long)w["reset_at"]!));
                    if ((long?)w["limit_window_seconds"] <= 21600) five = meter; else week = meter;
                }
                return new(Five: five, Week: week, Plan: data?["plan_type"]?.ToString(), Credits: (bool?)data?["credits"]?["unlimited"] == true ? "无限" : decimal.TryParse(data?["credits"]?["balance"]?.ToString(), out var credits) && credits > 0 ? credits.ToString("N0") : null);
            }
            var root = Endpoint.Root(p.Url);
            var restricted = Endpoint.ClientOnly(root);
            var usage = restricted ? null : (await Get(new(root, "api/usage/token/"), p.Secret))?["data"];
            if (usage?["object"]?.ToString() == "token_usage")
            {
                var own = usage["total_available"]; var user = usage["user_quota"]?["total_available"];
                var amount = (bool?)usage["unlimited_quota"] == true ? user ?? own : own ?? user;
                if (decimal.TryParse(amount?.ToString(), out var credit)) return new(credit * p.Ratio / 500000);
            }
            var details = await Get(new(root, "v1/usage"), p.Secret);
            var daily = new Dictionary<DateOnly,decimal>();
            if (details?["daily_usage"] is JsonArray days)
                foreach (var row in days.OfType<JsonObject>())
                    if (DateOnly.TryParse(row["date"]?.ToString(),out var date) && decimal.TryParse((row["actual_cost"] ?? row["cost"])?.ToString(),out var cost))
                        daily[date] = cost * p.Ratio;
            if (restricted && details == null) return new(Note: "Akko 未提供此额度接口");
            Meter? Seat(string prefix, TimeSpan duration)
            {
                var sub = details?["subscription"];
                if (!double.TryParse(sub?[prefix + "_limit_usd"]?.ToString(), out var limit) || limit <= 0) return null;
                double.TryParse(sub?[prefix + "_usage_usd"]?.ToString(), out var used);
                DateTimeOffset? reset = DateTimeOffset.TryParse(sub?[prefix + "_window_start"]?.ToString(), out var start) ? start + duration : null;
                if (reset <= DateTimeOffset.Now) { used = 0; reset = null; }
                return new(Math.Clamp(100 * (limit - used) / limit, 0, 100), reset, Math.Max(0, limit - used));
            }
            var fiveHour = Seat("five_hour", TimeSpan.FromHours(5)); var weekly = Seat("weekly", TimeSpan.FromDays(7));
            if (fiveHour != null || weekly != null) return new(decimal.TryParse(details?["balance"]?.ToString(), out var seatBalance) ? seatBalance * p.Ratio : null, fiveHour, weekly, details?["planName"]?.ToString(), Daily: daily);
            if (decimal.TryParse((details?["balance"] ?? details?["remaining"])?.ToString(), out var money)) return new(money * p.Ratio, Note: restricted ? "Akko 仅返回余额" : null, Daily: daily);
            if (restricted) return new(Note: "Akko 未返回可显示的订阅额度");
            return new(Note: "暂无余额数据");
        }
        catch (HttpRequestException ex) { return new(Note: ex.StatusCode switch {
            HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden => "额度查询未获授权，请检查 Key 权限",
            HttpStatusCode.TooManyRequests => "额度查询过于频繁，请稍后刷新",
            _ when ex.HttpRequestError == HttpRequestError.SecureConnectionError => "额度查询失败，无法建立安全连接",
            _ when ex.StatusCode != null => $"额度查询失败（HTTP {(int)ex.StatusCode}）",
            _ => "额度查询失败，请检查网络连接"
        }); }
        catch (OperationCanceledException) { return new(Note: "额度查询超时，可点击刷新重试"); }
        catch (Exception) { return new(Note: "暂时无法读取额度"); }
    }
}
