using System.IO;
using System.Text;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Swapdeck;
using System.Net;
using System.Net.Http;
using System.Text.Json;
class Tests {
    static int passed;
    static void Check(bool ok,string label){if(!ok)throw new Exception(label);Console.WriteLine("PASS "+label);passed++;}
    [STAThread] static int Main(string[] args){
        try { Run(args); return 0; }
        catch (Exception ex) { Console.Error.WriteLine(ex); return 1; }
    }
    static void Run(string[] args){
        if(args is ["--routing-fixture", var folder, var endpoint] && Uri.TryCreate(endpoint,UriKind.Absolute,out var mockUrl) && mockUrl.IsLoopback){
            RoutingFixture(new Paths(folder,folder,Path.Combine(folder,"data"),Path.Combine(folder,"library")),endpoint);
            return;
        }
        if(args.Length==2 && args[0]=="--restart-fixture"){
            var name=Path.GetFileNameWithoutExtension(args[1]);
            if(!name.StartsWith("SwapdeckTestWindow"))throw new ArgumentException();
                        int probes=0;
            try {
                DesktopRestart.Close(name, () => ++probes >= 2).GetAwaiter().GetResult();
                throw new Exception("Busy guard did not stop the forced exit");
            } catch (InvalidOperationException ex) when (ex.Message.Contains("已取消强制退出")) {
                Check(true,"busy guard rechecked before force");
            }
            var restart=DesktopRestart.Close(name, () => false).GetAwaiter().GetResult()??throw new Exception("Fixture window not found");
            restart.Reopen().GetAwaiter().GetResult();
            Check(true,"desktop window closed and relaunched");
            return;
        }
        string package=@"C:\Program Files\WindowsApps\OpenAI.Codex_1.0_x64__example\app";
        Check(DesktopRestart.IsDesktopPath("Codex",Path.Combine(package,"ChatGPT.exe")),"Store Codex GUI");
        Check(!DesktopRestart.IsDesktopPath("Codex",Path.Combine(package,"resources","codex.exe")),"ignore bundled CLI");
        Check(!DesktopRestart.IsDesktopPath("Codex",@"C:\Apps\ChatGPT\ChatGPT.exe"),"ignore separate ChatGPT");
        using(var siteHttp=new HttpClient(new GroupFixture())){
            var result=new Sub2Api(siteHttp).Login("fixture","fixture","",()=>null,false).GetAwaiter().GetResult();
            Check(result.SiteKey==42,"mixed-case ChatGPT group and string ID through login");
        }
        var dir=Directory.CreateTempSubdirectory("SwapdeckTest-").FullName;
        var paths=new Paths(dir,Path.Combine(dir,"codex"),Path.Combine(dir,"data"),Path.Combine(dir,"library"));
        var vault=new Vault(paths);var state=vault.Load();var clients=new Clients(paths,state);var tx=new SwitchFiles(paths);
        var p=new Profile(Guid.NewGuid(),"Claude","Akko","https://akko.gocode.de5.net","fixture-value");
        state.Cards.Add(p);vault.Save(state);
        Check(vault.Load().Cards.Single()==p&&!Encoding.UTF8.GetString(File.ReadAllBytes(Path.Combine(paths.Data,"profiles.bin"))).Contains(p.Secret),"DPAPI vault");
        Files.Write(paths.Settings,Files.Json(new{theme="dark",env=new{OTHER="keep",CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="0"}}));
        var previous=Guid.NewGuid();Files.Write(Path.Combine(paths.Library,"_meta.json"),Files.Json(new{appliedId=previous,entries=Array.Empty<object>()}));
        Files.Write(Path.Combine(paths.Library,previous+".json"),Files.Json(new{keep=true}));
        tx.Commit(clients.Claude(p));var settings=Files.Object(paths.Settings);
        Check(settings["theme"]?.ToString()=="dark"&&settings["env"]?["OTHER"]?.ToString()=="keep"&&settings["env"]?["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"]?.ToString()=="1","Akko CLI merge");
        Check(clients.Active("Claude")==p.Id&&(bool?)Files.Object(Path.Combine(paths.Library,p.Id+".json"))["keep"]==true,"desktop library switch");
        tx.Commit(clients.Claude(p with{Url="https://example.invalid"}));
        Check(Files.Object(paths.Settings)["env"]?["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"]?.ToString()=="0","restore traffic preference");

        var mock=new AkkoFixture();
        using var http=new HttpClient(new RelayGuard(mock));
        var reading=new Balances(http).Read(p).GetAwaiter().GetResult();
        Check(mock.Calls==1 && reading.Five is { Remaining:75, Left:30 } && reading.Week is { Remaining:90, Left:180 } && reading.Plan=="席位","Akko subscription via a single read-only usage request");
        foreach (var (method,url) in new[]{
            (HttpMethod.Post,p.Url+"/v1/usage"),(HttpMethod.Post,p.Url+"/v1/messages"),
            (HttpMethod.Get,p.Url+"/v1/responses"),(HttpMethod.Get,p.Url+"/v1/usage?other=1"),
            (HttpMethod.Get,"https://sub.akko.gocode.de5.net/v1/usage"),(HttpMethod.Get,"https://AKKO.gocode.de5.net./other")})
        {
            using var request=new HttpRequestMessage(method,url);
            try { using var response=http.SendAsync(request).GetAwaiter().GetResult(); }
            catch (InvalidOperationException) {}
        }
        Check(mock.Calls==1,"Akko blocks model requests and non-allowlisted destinations");
        var config="model = \"abc\"\n[tool]\nopenai_base_url = \"keep\"\n";Files.Write(paths.Config,Encoding.UTF8.GetBytes(config));
        var codex=p with{Client="Codex",Id=Guid.NewGuid()};
        tx.Commit(clients.Codex(codex,"https://example.invalid/v1"));
        Check(File.ReadAllText(paths.Config).EndsWith(config)&&Files.Object(paths.Auth)["OPENAI_API_KEY"]?.ToString()==p.Secret,"Codex scoped TOML + auth");
        Files.Write(paths.Auth,Files.Json(new{tokens=new{account_id="test-account",access_token="fixture-token"}}));
        Check(clients.RememberLogin()&&!clients.RememberLogin(),"remember login without duplication");
        var account=state.Cards.Last();tx.Commit(clients.Codex(account,null));
        Check(TopLevelToml.Set(clients.Toml,"openai_base_url",null)==config&&clients.Active("Codex")==account.Id,"official account restores provider");
        var custom = "\"model_provider\" = 'previous' # keep\r\n" +
            "rules = \"\"\"\n[not_a_table]\nmodel_provider = 'example'\n\"\"\"\r\n" +
            "[model_providers.previous]\r\nbase_url = 'https://example.invalid'\r\n";
        var expected = custom.Replace("'previous' # keep", "\"openai\" # keep");
        foreach (var target in new Profile?[] { account, codex with {Url=Sub2Api.Site}, null }) {
            Files.Write(paths.Config, Encoding.UTF8.GetBytes(custom));
            string? url=target is {Official:false}?Sub2Api.Site+"/v1":null;
            tx.Commit(clients.Codex(target,url));
            var actual=File.ReadAllText(paths.Config);
            Check(TopLevelToml.Get(actual,"openai_base_url")==(url?.Replace("https://","wss://") ?? "wss://chatgpt.com/backend-api/codex") &&
                TopLevelToml.Set(actual,"openai_base_url",null)==expected,
                "custom provider takeover: "+(target==null?"new login":target.Official?"official":"Lazymice"));
        }
        var abc=Path.Combine(dir,"sample");Files.Write(abc,[1,2,3]);
        RoutingFixture(new Paths(dir,Path.Combine(dir,"routing"),Path.Combine(dir,"routing-data"),paths.Library),"http://127.0.0.1:47844/v1");
        Files.Write(Path.Combine(paths.Data,"pending.bin"),Files.Protect(Files.Json(new Dictionary<string,byte[]?>{[abc]=[4,5]})));tx.Recover();
        Check(File.ReadAllBytes(abc).SequenceEqual(new byte[]{4,5}),"recover interrupted switch");
        var log=Path.Combine(paths.Codex,"sessions","test.jsonl");Files.Write(log,Encoding.UTF8.GetBytes("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n"));
        Check(Activity.Busy(paths,"Codex"),"busy client guard");File.AppendAllText(log,"{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}\n");
        Check(!Activity.Busy(paths,"Codex"),"completed turn");
        if(args.Length>=2){var bytes=File.ReadAllBytes(args[0]);var sig=File.ReadAllBytes(args[1]);Updates.Verify(bytes,sig);bytes[0]^=1;
            try{Updates.Verify(bytes,sig);throw new Exception("unsigned update");}catch(InvalidDataException){}Check(true,"signed manifest and tamper rejection");}
        if(args.Length>=3){
            p=p with{Name="示例席位",Url="https://demo.invalid"};state.Cards[0]=p;state.Tab="Claude";state.Cards.Add(p with{Id=Guid.NewGuid(),Name="备用中转",Url="https://example.invalid"});vault.Save(state);tx.Commit(clients.Claude(p));
            var app=new Application();var win=new MainWindow(paths);
            var flags=System.Reflection.BindingFlags.Instance|System.Reflection.BindingFlags.NonPublic|System.Reflection.BindingFlags.DeclaredOnly;
            void Call(string method,params object[] values)=>typeof(MainWindow).GetMethod(method,flags)!.Invoke(win,values);
            T Field<T>(string field)=>(T)typeof(MainWindow).GetField(field,flags)!.GetValue(win)!;
            void Snapshot(FrameworkElement visual,string name,int width,int height){
                visual.Measure(new Size(width,height));visual.Arrange(new Rect(0,0,width,height));visual.UpdateLayout();
                var bmp=new RenderTargetBitmap(width*2,height*2,192,192,PixelFormats.Pbgra32);bmp.Render(visual);
                var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bmp));
                using var file=File.Create(Path.Combine(Path.GetDirectoryName(args[2])!,name+".png"));encoder.Save(file);
            }
            var data=Field<Accounts>("state");var readings=Field<Dictionary<Guid,Reading>>("readings");
            readings[p.Id]=new(52,new Meter(94,DateTimeOffset.Now.AddHours(3),24.3),new Meter(82,DateTimeOffset.Now.AddDays(4),127.4),"席位");
            readings[account.Id]=new(Five:new Meter(92,DateTimeOffset.Now.AddHours(4)),Week:new Meter(87,DateTimeOffset.Now.AddDays(6)),Plan:"Plus",Credits:"1,024");
            var mockRelay=new Profile(Guid.NewGuid(),"Codex","示例中转","https://example.invalid","fixture");data.Cards.Add(mockRelay);readings[mockRelay.Id]=new(65.25m);
            tx.Commit(clients.Codex(account,null));
            var spend=Field<SpendBook>("spend");var history=Field<History>("usage");
            for(int i=0;i<30;i++){var date=DateOnly.FromDateTime(DateTime.Today.AddDays(i-29));var c=1+i%6;
                history.Rows[("Claude",date,"Claude 示例模型")]=new(2000,5000,700,c);
                history.Rows[("Codex",date,"Codex 示例模型")]=new(3100,6000,1200,c/2.0);
                if(!spend.Cards.ContainsKey(p.Id))spend.Cards[p.Id]=new Spend();spend.Cards[p.Id].Daily[date]=c;}
            var visual=(FrameworkElement)win.Content;
            var inactive=data.Cards.Single(card=>card.Name=="备用中转");
            var inactiveReading=reading;
            if(args.Length>=4)
            {
                using var replay=new HttpClient(new AkkoFixture(File.ReadAllText(args[3])));
                inactiveReading=new Balances(replay).Read(p with {Url="https://akko.gocode.de5.net"}).GetAwaiter().GetResult();
            }
            Check(inactiveReading.Five?.Left!=null && inactiveReading.Week?.Left!=null,"subscription has both remaining amounts");
            readings[inactive.Id]=inactiveReading;
            data.Tab="Claude";Call("Render");
            var cards=Field<System.Windows.Controls.StackPanel>("Cards");
            IEnumerable<string> Labels(DependencyObject parent)
            {
                if(parent is System.Windows.Controls.TextBlock label) yield return label.Text;
                for(int i=0;i<VisualTreeHelper.GetChildrenCount(parent);i++)
                    foreach(var text in Labels(VisualTreeHelper.GetChild(parent,i)))yield return text;
            }
            var miniRows=((System.Windows.Controls.StackPanel)((System.Windows.Controls.Border)cards.Children[1]).Child).Children.OfType<System.Windows.Controls.Primitives.UniformGrid>().ToArray();
            foreach(var meter in new[]{inactiveReading.Five!,inactiveReading.Week!})
                Check(miniRows.Any(row=>row.Children.Count==20 && row.ToolTip.ToString()!.Contains(meter.Remaining.ToString("0")+"%")),"inactive quota strip exposes remaining percentage");
            readings[inactive.Id]=new Reading(Note:"额度查询超时");Call("Render");
            Check(Labels(cards.Children[1]).Contains("额度查询超时"),"inactive card shows query failure");
            readings[inactive.Id]=inactiveReading;
            foreach(bool dark in new[]{false,true}){
                Call("ApplyPalette",dark);
                foreach(var tab in new[]{"Claude","Codex","用量"}){
                    data.Tab=tab;Call("Render");Snapshot(visual,tab+(dark?"-dark":"-light"),385,650);
                    if(!dark&&tab!="用量"){Call("ShowChoices");Snapshot(visual,tab+"-add",385,650);Call("CloseChoices");}
                }
            }
            data.Tab="用量";Call("Render");
            var clickEvent=System.Windows.Controls.Primitives.ButtonBase.ClickEvent;
            IEnumerable<T> Descendants<T>(DependencyObject root) where T:DependencyObject{
                if(root is T typed) yield return typed;
                for(int i=0;i<VisualTreeHelper.GetChildrenCount(root);i++)foreach(var child in Descendants<T>(VisualTreeHelper.GetChild(root,i)))yield return child;
            }
            void Filter(string name,bool last=false){
                var buttons=Descendants<System.Windows.Controls.Button>(cards).Where(b=>Equals(b.Content,name));
                (last?buttons.Last():buttons.First()).RaiseEvent(new RoutedEventArgs(clickEvent));}
            double[] Heights(){cards.Measure(new Size(353,double.PositiveInfinity));return cards.Children.OfType<System.Windows.Controls.Border>().Select(x=>x.DesiredSize.Height).ToArray();}
            var normal=Heights();Filter("今日");Filter("Codex");
            Check(Heights().SequenceEqual(normal) && Labels(cards).Contains("没有记录"),"empty scope preserves all card heights");
            Filter("30 天");Filter("30 天");
            Check(Field<int>("period")==0 && Heights().SequenceEqual(normal),"double-click 30 days enters fixed-height lifetime view");
            Filter("全部",true);Check(Field<int>("period")==30,"single click returns to 30 days");
            Filter("全部");var chart=Descendants<System.Windows.Controls.Primitives.UniformGrid>(cards.Children[0]).Single(g=>g.Columns==30);
            chart.Children[0].RaiseEvent(new System.Windows.Input.MouseEventArgs(System.Windows.Input.Mouse.PrimaryDevice,0){RoutedEvent=UIElement.MouseEnterEvent});
            Check(Heights().SequenceEqual(normal) && Labels(cards.Children[0]).Any(t=>t.EndsWith(" 花费")),"hover updates summary without moving cards");
            var scroll = ((System.Windows.Controls.Grid)visual).Children.OfType<System.Windows.Controls.ScrollViewer>().Single();
            Snapshot(visual,"usage-compact",320,420);
            scroll.ScrollToBottom();
            visual.UpdateLayout();
            Check(scroll.ComputedVerticalScrollBarVisibility == Visibility.Collapsed &&
                  scroll.ScrollableHeight > 0 && Math.Abs(scroll.VerticalOffset-scroll.ScrollableHeight)<1,
                  "compact usage page reaches bottom with scrollbar hidden");
            new System.Windows.Interop.WindowInteropHelper(win).EnsureHandle();
            Check(win.Width==385 && win.MinWidth==385 && win.MaxWidth==385 && win.Height==650 && win.MaxHeight==win.MinHeight,"fixed 385 by 650 window");
            Call("ApplyPalette",false);
            var settingsDialog=new SettingsDialog(win,data,()=>{},()=>{},()=>{});Snapshot((FrameworkElement)settingsDialog.Content,"settings",380,300);
            var editor=new EditDialog(win,"Claude",null);Snapshot((FrameworkElement)editor.Content,"editor",348,420);
            Check(true,"10 reference states rendered with fixture data");
        }
        Directory.Delete(dir,true);Console.WriteLine(passed+" checks passed");
    }
    static void RoutingFixture(Paths paths,string endpoint)
    {
        var a=new Profile(Guid.NewGuid(),"Codex","A",endpoint,"fixture-account-a");
        var b=a with{Id=Guid.NewGuid(),Name="B",Secret="fixture-account-b"};
        var clients=new Clients(paths,new Accounts{Cards=[a,b]});var tx=new SwitchFiles(paths);
        var config=$$"""
            model_provider = "OpenAI"
            [model_providers.OpenAI]
            name = "fixture"
            base_url = "{{endpoint}}"
            wire_api = "responses"
            requires_openai_auth = true
            experimental_bearer_token = "fixture-account-a"
            http_headers = {HEADER}
            [model_providers.other]
            name = "other"
            base_url = "https://other.invalid/v1"
            experimental_bearer_token = "unrelated"
            """;
        Files.Write(paths.Config,Encoding.UTF8.GetBytes(config.Replace("HEADER","\"authorization\" = \"Bearer fixture-account-a\"")));
        tx.Commit(clients.Codex(a,endpoint));
        Files.Write(paths.Auth,Files.Json(new{auth_mode="apikey",OPENAI_API_KEY=b.Secret}));
        Check(clients.Active("Codex")==null,"reject conflicting default and resumed-thread credentials");
        foreach(var target in new[]{b,a,b}){
            tx.Commit(clients.Codex(target,endpoint));
            var actual=File.ReadAllText(paths.Config);
            Check(clients.Active("Codex")==target.Id && actual.Contains("Bearer "+target.Secret) &&
                actual.Contains("experimental_bearer_token = \""+target.Secret+"\"") &&
                actual.Contains("\"unrelated\""),"same-site alias and default switch to "+target.Name);
        }
    }
    sealed class GroupFixture : HttpMessageHandler {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken token) {
            var data=request.RequestUri!.AbsolutePath switch {
                "/api/v1/auth/login" => """{"access_token":"fixture"}""",
                "/api/v1/groups/available" => """[{"name":" ChatGPT ","id":"7"}]""",
                "/api/v1/keys" when request.Method==HttpMethod.Get => """{"items":[{"name":"Swapdeck","group_id":7,"id":42,"key":"fixture"}]}""",
                _ => throw new Exception("unexpected request")
            };
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK){Content=new StringContent("{\"code\":0,\"data\":"+data+"}")});
        }
    }
    sealed class AkkoFixture(string? payload=null):HttpMessageHandler
    {
        public int Calls;
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage req,CancellationToken ct)
        {
            Calls++;
            if(req.Method!=HttpMethod.Get || req.RequestUri?.AbsoluteUri!="https://akko.gocode.de5.net/v1/usage" ||
                req.Content!=null || req.Headers.Authorization?.Parameter!="fixture-value")
                throw new Exception("Unexpected Akko request");
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK){Content=new StringContent(
                payload ?? """{"planName":"席位","subscription":{"five_hour_limit_usd":40,"five_hour_usage_usd":10,"weekly_limit_usd":200,"weekly_usage_usd":20}}""")});
        }
    }
}
