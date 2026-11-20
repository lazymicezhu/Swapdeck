using System.Net.Http.Json;
using System.Windows;
using System.Windows.Controls;
namespace Swapdeck;

public sealed class Sub2Api(HttpClient http)
{
    public const string Site = "https://api.lazymicezhu.com";
    async Task<JsonNode> Call(string path, object? body = null, string? bearer = null)
    {
        using var req = new HttpRequestMessage(body == null ? HttpMethod.Get : HttpMethod.Post, Site + "/api/v1/" + path);
        if (body != null) req.Content = JsonContent.Create(body);
        if (bearer != null) req.Headers.Authorization = new("Bearer", bearer);
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(20));
        using var response = await http.SendAsync(req, timeout.Token);
        if (!response.IsSuccessStatusCode) throw new InvalidOperationException("站点返回 HTTP " + (int)response.StatusCode);
        var result = JsonNode.Parse(await response.Content.ReadAsStringAsync(timeout.Token));
        if ((int?)result?["code"] is { } code && code != 0) throw new InvalidOperationException("站点拒绝了此次操作，请检查登录信息。");
        return result?["data"] ?? result ?? throw new InvalidDataException("站点响应为空。");
    }
    static IEnumerable<JsonNode?> List(JsonNode n) => n as JsonArray ?? n["items"] as JsonArray ?? [];
    public async Task<Profile> Login(string login, string password, string invite, Func<string?> askCode, bool register)
    {
        var email = login.Contains('@') ? login : login + "@lm.local";
        var r = register ? await Call("auth/register", new { email, password, invitation_code = invite }) : await Call("auth/login", new { email, password });
        if ((bool?)r["requires_2fa"] == true)
        {
            var code = askCode() ?? throw new OperationCanceledException("已取消验证");
            r = await Call("auth/login/2fa", new { temp_token = r["temp_token"]?.ToString(), totp_code = code });
        }
        var token = r["access_token"]?.ToString() ?? throw new InvalidDataException("登录响应缺少访问令牌。");
        var available = await Call("groups/available", bearer: token);
        var groups = available as JsonArray ?? (available as JsonObject)?["items"] as JsonArray
            ?? throw new InvalidDataException("无法识别站点返回的分组列表。");
        var match = groups.OfType<JsonObject>().FirstOrDefault(g =>
            string.Equals(g["name"]?.ToString()?.Trim(), "chatgpt", StringComparison.OrdinalIgnoreCase));
        if (match == null)
            throw new InvalidOperationException("已登录，站点返回的可用分组中没有 ChatGPT。请检查此账号在 Lazymice 的分组配置。");
        if (!int.TryParse(match["id"]?.ToString(), out var group))
            throw new InvalidDataException("已找到 ChatGPT 分组，但站点返回的分组 ID 无效。");
        var keys = List(await Call("keys?page=1&page_size=100", bearer: token));
        var key = keys.FirstOrDefault(k => k?["name"]?.ToString() == "Swapdeck" && k["group_id"]?.ToString() == group.ToString() && k["status"]?.ToString() is null or "active" && k["key"]?.ToString() is { } text && !text.Contains('*'));
        key ??= await Call("keys", new { name = "Swapdeck", group_id = (int)group }, token);
        var secret = key["key"]?.ToString() ?? throw new InvalidDataException("无法读取站点分配的 Key。");
        return new(Guid.NewGuid(), "Codex", login, Site, secret, SiteAccess: token, SiteKey: (int?)key["id"]);
    }
    public async Task<string> Records(Profile p)
    {
        var data = List(await Call("usage?page=1&page_size=50&sort_by=created_at&sort_order=desc&api_key_id=" + p.SiteKey, bearer: p.SiteAccess));
        var rows = data.Select(r => r?["created_at"] + "   " + r?["model"] + "   $" + (r?["actual_cost"] ?? r?["total_cost"]));
        return string.Join("\n", rows.DefaultIfEmpty("暂无记录"));
    }
}
public sealed class SiteDialog : FormWindow
{
    public Profile? Result { get; private set; }
    bool busy;
    public SiteDialog(Window owner, Sub2Api site) : base(owner, "Lazymice 中转")
    {
        var login = new TextBox(); var password = new PasswordBox(); var invite = new TextBox();
        Field("账号或邮箱", login); Field("密码", password); Field("邀请码（注册时使用）", invite);
        async void Submit(bool register)
        {
            if (busy) return; busy = true; Fields.IsEnabled = false;
            try
            {
                Result = await site.Login(login.Text.Trim(), password.Password, invite.Text.Trim(), () =>
                {
                    var code = new CodeDialog(this); return code.ShowDialog() == true ? code.Code : null;
                }, register); DialogResult = true;
            }
            catch (Exception ex) { MessageBox.Show(this, ex.Message, Title); }
            finally { Fields.IsEnabled = true; busy = false; }
        }
        ActionButton("登录", () => Submit(false), true); ActionButton("注册", () => Submit(true));
    }
    sealed class CodeDialog : FormWindow
    {
        readonly TextBox box = new(); public string Code => box.Text.Trim();
        public CodeDialog(Window w) : base(w, "双重验证") { Field("验证码", box); ActionButton("确定", () => DialogResult = true, true); }
    }
}
