using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using Microsoft.Win32;
namespace Swapdeck;

public partial class MainWindow : Window
{
    readonly Paths paths; readonly Vault vault; readonly Accounts state; readonly Clients clients;
    readonly SpendBook spend; readonly Sub2Api site = new(RelayGuard.Client()); readonly Updates updates = new(); readonly Balances balances = new(RelayGuard.Client());
    readonly Dictionary<Guid, Reading> readings = []; History usage = new(); bool refreshing, switching, exitRequested, waitingForLogin;
    readonly DispatcherTimer toastTimer = new() { Interval = TimeSpan.FromSeconds(6) };
    public MainWindow(Paths paths)
    {
        this.paths = paths; spend = new(paths); vault = new(paths); state = vault.Load(); clients = new(paths, state);
        InitializeComponent(); Theme(); Activated += (_, _) => { Theme(); }; Topmost = state.Topmost;
        if(state.Left is double left && state.Top is double top && double.IsFinite(left) && double.IsFinite(top)){
            WindowStartupLocation=WindowStartupLocation.Manual;Left=Math.Clamp(left,SystemParameters.VirtualScreenLeft,SystemParameters.VirtualScreenLeft+Math.Max(0,SystemParameters.VirtualScreenWidth-Width));Top=Math.Clamp(top,SystemParameters.VirtualScreenTop,SystemParameters.VirtualScreenTop+Math.Max(0,SystemParameters.VirtualScreenHeight-40));
        }
        ToastBox.MouseLeftButtonUp+=(_,_)=>ToastBox.Visibility=Visibility.Collapsed;
        PreviewKeyDown+=(_,e)=>{if(e.Key==System.Windows.Input.Key.Escape)CloseChoices();};
        MouseLeftButtonDown+=(_,e)=>{if(!e.Handled && e.LeftButton==System.Windows.Input.MouseButtonState.Pressed)DragMove();};
        Timer(.5,()=>{if(IsVisible && WindowState!=WindowState.Minimized && state.Tab!="用量" && Choices.Visibility!=Visibility.Visible && !Cards.Children.OfType<Border>().Any(card=>card.ContextMenu?.IsOpen==true))Render();return Task.CompletedTask;});
        toastTimer.Tick += (_, _) => { ToastBox.Visibility = Visibility.Collapsed; toastTimer.Stop(); };
        Loaded += async (_, _) =>
        {
            await Guard(async () =>
            {
                if (clients.RememberLogin()) Save();
                Render(); _ = Update(false); await Refresh();
            });
        };
        Timer(5, Refresh); Timer(360, () => Update(false)); Timer(0.15, () => { if (!switching && (clients.RememberLogin() || waitingForLogin && clients.SavedLogin()!=null)) { waitingForLogin=false; Save(); Render(); } return Task.CompletedTask; });
        Closing += (_, e) =>
        {
            if (WindowState==WindowState.Normal){state.Left=Left;state.Top=Top;Save();}
            if (!exitRequested) { e.Cancel = true; WindowState=WindowState.Minimized; return; }
            if (switching) { e.Cancel = true; Toast("正在调用中，请稍后退出"); }

        };
    }
    void Timer(double minutes, Func<Task> action) { var timer = new DispatcherTimer { Interval = TimeSpan.FromMinutes(minutes) }; timer.Tick += async (_, _) => await Guard(action); timer.Start(); }
    void Theme()
    {
        bool dark = (int?)Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 1) == 0;
        ApplyPalette(dark);
    }
    void ApplyPalette(bool dark)
    {
        night = dark;
        foreach (var (key, light, nightColor) in new[] { ("Warn","#F08A24","#F5A04A"), ("Alarm","#E5484D","#FF6A5C"), ("WindowBg", "#ECECEE", "#1B1B1D"), ("Text", "#111214", "#F3F4F6"), ("Ink", "#0E0F12", "#F2F2F4"), ("InkText", "#F3F4F6", "#111214"), ("InkMuted", "#9BA0AA", "#6E727A"), ("BackDeep", "#F6F6F7", "#242427"), ("Muted", "#737780", "#9397A0"), ("Back", "#FFFFFF", "#2A2A2D"), ("Link", "#2F6BFF", "#5B8CFF") }) Resources[key] = Brush(dark ? nightColor : light);
    }
    static SolidColorBrush Brush(string value) => new((Color)ColorConverter.ConvertFromString(value));
    Brush B(string key) => (Brush)Resources[key];
    void Save() => vault.Save(state);
    async Task Guard(Func<Task> action) { try { await action(); } catch (Exception ex) { Toast(ex is JsonException ? "配置文件格式异常，请检查后重试。" : ex.Message); } }
    void Toast(string text) { ToastText.Text = text; ToastBox.Visibility = Visibility.Visible; ToastBox.UpdateLayout();
        if(ToastBlur.ActualWidth>0 && ToastBlur.ActualHeight>0){var origin=ToastBlur.TranslatePoint(new Point(),PageScroll);ToastBlur.Fill=new VisualBrush(PageScroll){ViewboxUnits=BrushMappingMode.Absolute,Viewbox=new Rect(origin,new Size(ToastBlur.ActualWidth,ToastBlur.ActualHeight)),Stretch=Stretch.Fill};}
        toastTimer.Stop(); toastTimer.Start(); }
    async Task Refresh()
    {
        if (refreshing) return; refreshing = true;
        RefreshButton.IsEnabled=false;var spin=new System.Windows.Shapes.Ellipse{Width=13,Height=13,Stroke=B("Muted"),StrokeThickness=1.5,StrokeDashArray=new DoubleCollection{16,10},RenderTransformOrigin=new(.5,.5),RenderTransform=new RotateTransform()};((RotateTransform)spin.RenderTransform).BeginAnimation(RotateTransform.AngleProperty,new System.Windows.Media.Animation.DoubleAnimation(0,360,TimeSpan.FromSeconds(.8)){RepeatBehavior=System.Windows.Media.Animation.RepeatBehavior.Forever});RefreshButton.Content=spin;
        try
        {
            await Task.WhenAll(state.Cards.ToArray().Select(RefreshCard));
            usage = await Task.Run(() => History.Scan(paths)); RefreshButton.ToolTip = DateTime.Now.ToString("刷新（上次 HH:mm:ss）"); Render();
        }
        finally { refreshing = false;RefreshButton.Content="\uE72C";RefreshButton.IsEnabled=true; }
    }
    async Task RefreshCard(Profile profile)
    {
        var value = await balances.Read(profile);
        if (!state.Cards.Contains(profile)) return;
        readings[profile.Id] = value;
        if (value.Balance.HasValue || value.Daily?.Count>0) spend.Record(profile, value);
        Render();
    }
    async void RefreshClick(object s, RoutedEventArgs e) => await Guard(Refresh);
    async Task Update(bool manual)
    {
        if(!manual && !state.AutoUpdate)return;
        try
        {
            var result = await updates.Check(message => !switching && MessageBox.Show(this, message, "切号更新", MessageBoxButton.YesNo) == MessageBoxResult.Yes);
            if (manual) Toast(result);
        }
        catch when (!manual) { }
    }
    async Task Switch(Profile? target)
    {
        if (switching) return; switching = true;
        var client = target?.Client ?? "Codex"; DesktopRestart? restart = null; bool desktopClosed = false;
        try
        {
            if (Activity.Busy(paths, client)) throw new InvalidOperationException("正在调用中，请等结束后再执行切换。");
            if (client == "Codex" && clients.RememberLogin()) Save();
            if (target == null && File.Exists(paths.Auth) && clients.SavedLogin() == null) throw new InvalidOperationException("当前登录格式未识别，请先在 Codex 中管理该账号。");
            Dictionary<string, byte[]?> change;
            if (client == "Claude") change = clients.Claude(target!);
            else
            {
                string? url = null;
                if (target is { Official: false })
                {
                    url = new Uri(Endpoint.Root(target.Url), "v1").AbsoluteUri;
                }
                change = clients.Codex(target, url);
            }
            restart = state.Restart ? await DesktopRestart.Close(client, () => Activity.Busy(paths, client)) : null;
            desktopClosed = restart != null;
            new SwitchFiles(paths).Commit(change);
            Render();
            if (Cards.Children.Count > 0 && SystemParameters.ClientAreaAnimation)
            {
                var card = Cards.Children[0]; var move = new TranslateTransform(); card.RenderTransform = move;
                move.BeginAnimation(TranslateTransform.YProperty, new System.Windows.Media.Animation.DoubleAnimation(8, 0, TimeSpan.FromSeconds(.42)) { EasingFunction = new System.Windows.Media.Animation.BackEase { Amplitude = .25, EasingMode = System.Windows.Media.Animation.EasingMode.EaseOut } });
            }
            string result = client == "Claude" && !File.Exists(Path.Combine(clients.Library, "_meta.json")) ? "已切换 Claude Code，桌面端尚未配置第三方模式" : target == null ? "请在 Codex 中登录新账号" : "已切换至 " + target.Name;
            if (restart != null) { var closed = restart; restart = null; await closed.Reopen(); }
            if (client=="Codex") waitingForLogin=target==null;
            Toast(result + (state.Restart ? (desktopClosed ? "，" + client + " 已重启" : "，未检测到打开的桌面端，下次启动生效") : "，自动重启已关闭"));
        }
        finally { try { if (restart != null) await restart.Reopen(); } finally { switching = false; } }
    }
    Button Btn(string text, Action action) { var b = new Button { Content = text }; b.Click += (_, _) => action(); return b; }
    TextBlock Label(string text, double size, Brush color) => new() { Text = text, FontSize = size, Foreground = color, TextWrapping = TextWrapping.Wrap };
    void Render()
    {
        Tabs.Children.Clear(); Cards.Children.Clear();
        foreach (var t in new[] { "Claude", "Codex", "用量" })
        {
            var b = Btn(t, () => { CloseChoices(); state.Tab = t; Save(); Render(); Cards.BeginAnimation(OpacityProperty,new System.Windows.Media.Animation.DoubleAnimation(.55,1,TimeSpan.FromSeconds(.22))); }); b.FontSize = 12.5; b.Padding = new(14, 5, 14, 5); b.Margin=new(1,0,1,0); b.Foreground = B("Muted"); if (state.Tab == t) { b.Background = B("Ink"); b.Foreground = B("InkText"); b.FontWeight = FontWeights.SemiBold; }
            Tabs.Children.Add(b);
        }
        Footer.Visibility = state.Tab == "用量" ? Visibility.Collapsed : Visibility.Visible;
        if (state.Tab == "用量") { RenderUsage(); return; }
        bool claude = state.Tab == "Claude"; AddButton.Content = claude ? "＋  添加中转" : "＋  添加账号";
        var active = clients.Active(state.Tab);
        var cards = state.Cards.Where(p => p.Client == state.Tab).OrderByDescending(p => p.Id == active).ToList();
        if (cards.Count == 0) { var l = Label(claude ? "还没有中转。添加一个 Anthropic 兼容的地址和 Key。" : "在 Codex 里登录 ChatGPT 账号后，它会自动出现在这里。\n也可以在下方用 Lazymice 账号登录。", 12.5, B("Muted")); l.Margin = new(8, 80, 8, 0); l.TextAlignment = TextAlignment.Center; Cards.Children.Add(l); }
        foreach (var p in cards) DrawCard(p, p.Id == active);
    }
    static void Menu(ContextMenu m, string label, Action action) { var i = new MenuItem { Header = label }; i.Click += (_, _) => action(); m.Items.Add(i); }
    void AddClick(object s, RoutedEventArgs e)
    {
        ShowChoices();
    }
    void CloseChoices() { Choices.Visibility = Visibility.Collapsed; AddButton.Visibility = SlotOutline.Visibility = Visibility.Visible; }
    void ShowChoices()
    {
        ChoiceRows.Children.Clear(); Choices.Visibility = Visibility.Visible; AddButton.Visibility = SlotOutline.Visibility = Visibility.Collapsed;
        var scale=new ScaleTransform(.97,.97); Choices.RenderTransform=scale;Choices.RenderTransformOrigin=new(.5,1);
        var grow=new System.Windows.Media.Animation.DoubleAnimation(.97,1,TimeSpan.FromSeconds(.2));
        scale.BeginAnimation(ScaleTransform.ScaleXProperty,grow);scale.BeginAnimation(ScaleTransform.ScaleYProperty,grow);
        Choices.BeginAnimation(OpacityProperty,new System.Windows.Media.Animation.DoubleAnimation(0,1,TimeSpan.FromSeconds(.2)));
        var close = Btn("×", CloseChoices); close.Foreground = B("InkMuted"); ChoiceRows.Children.Add(Pair(Label("添加", 11, B("InkMuted")), close));
        void Row(string title, string hint, Action action)
        {
            var button = Btn("", () => { CloseChoices(); action(); }); button.HorizontalContentAlignment = HorizontalAlignment.Stretch;
            button.Template = new ControlTemplate(typeof(Button)) { VisualTree = new FrameworkElementFactory(typeof(ContentPresenter)) };
            var row = Pair(Strong(title, 14, B("InkText")), Label(hint + "   ›", 11.5, B("InkMuted"))); if(ChoiceRows.Children.Count>1)ChoiceRows.Children.Add(new Border{Height=1,Background=B("InkText"),Opacity=.12});row.Margin = new(0, 11, 0, 11); button.Content = row; if(title=="官方订阅" && waitingForLogin){button.IsEnabled=false;button.Opacity=.4;} ChoiceRows.Children.Add(button);
        }
        if (state.Tab == "Claude") { Row("中转", "填地址和 Key", () => Edit(null)); return; }
        Row("Lazymice 中转", "登录或注册", () => { var dialog = new SiteDialog(this, site); if (dialog.ShowDialog() == true && dialog.Result is { } profile) { var index = state.Cards.FindIndex(x => x.SiteAccess != null && x.Name == profile.Name); if (index < 0) state.Cards.Add(profile); else state.Cards[index] = profile with { Id = state.Cards[index].Id }; Save(); Render(); _ = Guard(Refresh); } });
        Row("官方订阅", "在 Codex 里登录", async () => { if (MessageBox.Show(this, "保存当前账号并切换至 Codex 登录页面？", "登录新账号", MessageBoxButton.YesNo) == MessageBoxResult.Yes) await Guard(() => Switch(null)); });

    }
    void CloseClick(object s, RoutedEventArgs e) => Close();
    void MinClick(object s, RoutedEventArgs e) => WindowState = WindowState.Minimized;
    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        var handle = new System.Windows.Interop.WindowInteropHelper(this).Handle;
        const int styleIndex = -16, maximizeBox = 0x10000;
        SetWindowLong(handle, styleIndex, GetWindowLong(handle, styleIndex) & ~maximizeBox);
    }
    [System.Runtime.InteropServices.DllImport("user32.dll", EntryPoint="GetWindowLongW")]
    private static extern int GetWindowLong(IntPtr handle, int index);
    [System.Runtime.InteropServices.DllImport("user32.dll", EntryPoint="SetWindowLongW")]
    private static extern int SetWindowLong(IntPtr handle, int index, int value);
    void Delete(Profile p)
    {
        if (clients.Active(p.Client) == p.Id) { Toast("请先切换到其他账号"); return; }
        if (MessageBox.Show(this, "删除「" + p.Name + "」？\n只删除保存的地址和 Key，聊天记录不受影响。", "切号", MessageBoxButton.YesNo) == MessageBoxResult.Yes) { state.Cards.Remove(p); Save(); Render(); }
    }
    void Edit(Profile? p)
    {
        var activeBefore = clients.Active(state.Tab); var dialog = new EditDialog(this, state.Tab, p); if (dialog.ShowDialog() != true) return;
        var value = dialog.Value!; if (p == null) state.Cards.Add(value); else state.Cards[state.Cards.IndexOf(p)] = value;
        Save(); Render(); if (p != null && p.Id == activeBefore) _ = Guard(() => Switch(value));
        _ = Guard(() => RefreshCard(value));
    }

    void SettingsClick(object s, RoutedEventArgs e) { new SettingsDialog(this, state, () => { Save(); Topmost = state.Topmost; }, async () => await Guard(() => Update(true)), () => { exitRequested = true; Close(); exitRequested = false; }).ShowDialog(); }
}
