using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;
namespace Swapdeck;

public class FormWindow : Window
{
    protected StackPanel Fields { get; } = new() { Margin = new(22) };
    protected System.Windows.Media.Brush SurfaceText { get; }
    protected System.Windows.Media.Brush Hint { get; }
    protected bool Settings { get; }
    protected StackPanel Actions { get; } = new() { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new(0, 16, 0, 0) };
    public FormWindow(Window owner, string title)
    {
        Owner = owner; Title = title; Settings = title == "设置"; Width = Math.Min(360, Math.Max(290, owner.ActualWidth - 14));
        FontFamily = owner.FontFamily; System.Windows.Documents.Typography.SetNumeralAlignment(this,FontNumeralAlignment.Tabular); Resources.MergedDictionaries.Add(owner.Resources);
        SizeToContent = SizeToContent.Height; WindowStartupLocation = WindowStartupLocation.CenterOwner; ResizeMode = ResizeMode.NoResize;
        WindowStyle = WindowStyle.None; AllowsTransparency = true; Background = System.Windows.Media.Brushes.Transparent; ShowInTaskbar = false;
        SurfaceText = (System.Windows.Media.Brush)FindResource(Settings ? "Text" : "InkText"); Hint = (System.Windows.Media.Brush)FindResource(Settings ? "Muted" : "InkMuted");
        Content = new Border { CornerRadius = new(16), Background = (System.Windows.Media.Brush)FindResource(Settings ? "Back" : "Ink"), Child = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = Fields } };
        MaxHeight = Math.Max(330, owner.ActualHeight - 20);
        Loaded += (_, _) => { if (owner is MainWindow w) w.Scrim.Visibility = Visibility.Visible; };
        Closed += (_, _) => { if (owner is MainWindow w) w.Scrim.Visibility = Visibility.Collapsed; };
        PreviewKeyDown += (_, e) => { if (e.Key == System.Windows.Input.Key.Escape) { Close(); e.Handled = true; } };
        Fields.Children.Add(new TextBlock { Text = title, Foreground = SurfaceText, FontSize = 16, FontWeight = FontWeights.SemiBold, Margin = new(0, 0, 0, 7) });
    }
    protected void Field(string label, Control input)
    {
        Fields.Children.Add(new TextBlock { Text = label, FontSize = 11.5, Foreground = Hint, Margin = new(0, 10, 0, 4) });
        input.Padding = new(0, 4, 0, 6); input.Background = System.Windows.Media.Brushes.Transparent; input.Foreground = SurfaceText; input.FontSize = 14; input.BorderBrush = Hint; input.BorderThickness = new(0, 0, 0, 1); Fields.Children.Add(input);
        if (input is TextBox tb) tb.CaretBrush = SurfaceText; if (input is PasswordBox pb) pb.CaretBrush = SurfaceText;
    }
    protected Button ActionButton(string title, Action action, bool primary = false)
    {
        var b = new Button { Content = title, Margin = new(3, 2, 3, 0), Padding = new(10, 6, 10, 6), IsDefault = primary, Foreground = primary ? (Settings ? System.Windows.Media.Brushes.White : (System.Windows.Media.Brush)FindResource("Ink")) : SurfaceText, Background = primary ? (Settings ? (System.Windows.Media.Brush)FindResource("Link") : SurfaceText) : System.Windows.Media.Brushes.Transparent };
        b.Click += (_, _) => action();
        if (Settings && !primary) { Fields.Children.Add(b); } else { if (!Fields.Children.Contains(Actions)) Fields.Children.Add(Actions); Actions.Children.Add(b); }
        return b;
    }
}
public sealed class EditDialog : FormWindow
{
    public Profile? Value { get; private set; }
    public EditDialog(Window owner, string client, Profile? old, bool renameOnly = false) : base(owner, old == null ? "添加中转" : old.Official || renameOnly ? "重命名" : "编辑中转")
    {
        var name = new TextBox { Text = old?.Name ?? "" }; Field("名称", name);
        var url = new TextBox { Text = old?.Url ?? "" }; var secret = new PasswordBox();
        var ratio = new TextBox { Text = (old?.Ratio ?? 1).ToString() };
        if (!renameOnly && old?.Official != true) { Field("Base URL", url); Field(old == null ? "API Key" : "API Key（留空保留原值）", secret); Field("充值比例（元 / 单位）", ratio); }
        ActionButton("取消", () => Close());
        var saveButton = ActionButton("保存", () =>
        {
            try
            {
                if (old != null && (renameOnly || old.Official)) { if (name.Text.Trim() == "") throw new InvalidDataException("请输入名称。"); Value = old with { Name = name.Text.Trim() }; }
                else
                {
                    var root = Endpoint.Root(url.Text); var key = secret.Password.Length == 0 ? old?.Secret : secret.Password;
                    if (string.IsNullOrWhiteSpace(key)) throw new InvalidDataException("请输入 API Key。");
                    if (!decimal.TryParse(ratio.Text, out var rate) || rate <= 0) throw new InvalidDataException("充值比例必须大于零。");
                    Value = new(old?.Id ?? Guid.NewGuid(), client, string.IsNullOrWhiteSpace(name.Text) ? root.Host : name.Text.Trim(), root.AbsoluteUri.TrimEnd('/'), key.Trim(), false, rate, old?.SiteAccess, old?.SiteKey);
                }
                DialogResult = true;
            }
            catch (Exception ex) { MessageBox.Show(this, ex.Message, Title); }
        }, true);
        void Validate() { saveButton.IsEnabled = renameOnly || old?.Official == true ? name.Text.Trim().Length > 0 : Uri.TryCreate(url.Text, UriKind.Absolute, out _) && (old != null || secret.Password.Length > 0) && decimal.TryParse(ratio.Text, out var n) && n > 0; saveButton.Opacity = saveButton.IsEnabled ? 1 : .42; }
        name.TextChanged += (_, _) => Validate(); url.TextChanged += (_, _) => Validate(); secret.PasswordChanged += (_, _) => Validate(); ratio.TextChanged += (_, _) => Validate(); Validate();
    }
}
public sealed class SettingsDialog : FormWindow
{
    public SettingsDialog(Window owner, Accounts state, Action save, Action update, Action exit) : base(owner, "设置")
    {
        Width=380;Height=300;SizeToContent=SizeToContent.Manual;
        var advanced=new ContextMenu();
        var originalHeader=(TextBlock)Fields.Children[0];originalHeader.Text="更新";
        void Toggle(string label, bool enabled, Action<bool> set)
        {
            var line = new DockPanel { Margin = new(0, 1, 0, 0), Background = (System.Windows.Media.Brush)FindResource("BackDeep") };
            var button = new System.Windows.Controls.Primitives.ToggleButton { Width = 36, Height = 18, Margin = new(7), IsChecked = enabled, ToolTip = label, Style = (Style)FindResource("SwitchStyle") };
            button.Click += (_, _) => { set(button.IsChecked == true); save(); }; DockPanel.SetDock(button, Dock.Right); line.Children.Add(button);
            line.Children.Add(new TextBlock { Text = label, Foreground = SurfaceText, Margin = new(9, 7, 0, 7) }); Fields.Children.Add(line);
        }
        Toggle("自动检查更新", state.AutoUpdate, v => state.AutoUpdate = v);
        var versionRow=new DockPanel{Background=(System.Windows.Media.Brush)FindResource("BackDeep"),Margin=new(0,1,0,10)};
        var check=new Button{Content="检查更新",Padding=new(10,3,10,3),Margin=new(5,3,5,3)};check.Click+=(_,_)=>update();
        DockPanel.SetDock(check,Dock.Right);versionRow.Children.Add(check);
        var version=new TextBlock{Text=typeof(MainWindow).Assembly.GetName().Version?.ToString(3),Foreground=Hint,VerticalAlignment=VerticalAlignment.Center};DockPanel.SetDock(version,Dock.Right);versionRow.Children.Add(version);
        versionRow.Children.Add(new TextBlock{Text="当前版本",Margin=new(9,7,0,7),Foreground=SurfaceText});Fields.Children.Add(versionRow);
        Toggle("窗口始终置顶", state.Topmost, v => state.Topmost = v);
        void AdvancedToggle(string label,bool current,Action<bool> apply){var item=new MenuItem{Header=label,IsCheckable=true,IsChecked=current};item.Click+=(_,_)=>{apply(item.IsChecked);save();};advanced.Items.Add(item);}
        AdvancedToggle("切换后重启已打开的客户端",state.Restart,v=>state.Restart=v);
        AdvancedToggle("Claude 中转同时用于 Claude Code",state.SyncCli,v=>state.SyncCli=v);
        const string run = @"Software\Microsoft\Windows\CurrentVersion\Run";
        using var startup = Registry.CurrentUser.OpenSubKey(run);
        Toggle("登录 Windows 时启动", startup?.GetValue("Swapdeck") != null, v => { using var k = Registry.CurrentUser.CreateSubKey(run); if (v) k.SetValue("Swapdeck", "\"" + Environment.ProcessPath + "\""); else k.DeleteValue("Swapdeck", false); });
        var library=new MenuItem{Header="选择 Claude 第三方配置目录"};advanced.Items.Add(library);library.Click+=(_,_)=>
        {
            var dialog = new OpenFolderDialog { Title = "选择含 _meta.json 的 configLibrary 目录" }; if (dialog.ShowDialog(this) == true)
            {
                if (!File.Exists(Path.Combine(dialog.FolderName, "_meta.json"))) { MessageBox.Show(this, "此目录缺少 _meta.json。"); return; }
                state.Library = dialog.FolderName; save();
            }
        };
        var quit=new MenuItem{Header="退出切号"};quit.Click+=(_,_)=>{Close();exit();};advanced.Items.Add(quit);
        var more=ActionButton("更多设置",()=>advanced.IsOpen=true,true);advanced.PlacementTarget=more;more.IsDefault=false;more.Background=System.Windows.Media.Brushes.Transparent;more.Foreground=Hint;Actions.Margin=new(0,36,0,0);ActionButton("完成", () => Close(), true);
    }
}
