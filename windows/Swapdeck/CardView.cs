using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
namespace Swapdeck;

public partial class MainWindow
{

    TextBlock Strong(string text, double size, Brush color)
    {
        var label = Label(text, size, color); label.FontWeight = FontWeights.SemiBold; label.TextWrapping = TextWrapping.NoWrap;
        label.TextTrimming = TextTrimming.CharacterEllipsis; return label;
    }
    TextBlock ShortName(string name,double size,Brush color)
    {
        var text=Strong(name,size,color);text.ToolTip=name;
        text.SizeChanged+=(_,_)=>{double width=text.ActualWidth;if(width<=0)return;
            double Measure(string s)=>new FormattedText(s,System.Globalization.CultureInfo.CurrentCulture,FlowDirection.LeftToRight,new Typeface(text.FontFamily,text.FontStyle,text.FontWeight,text.FontStretch),size,color,VisualTreeHelper.GetDpi(text).PixelsPerDip).WidthIncludingTrailingWhitespace;
            string shown=name;for(int n=name.Length-1;n>1 && Measure(shown)>width;n--)shown=name[..((n+1)/2)]+"…"+name[^(n/2)..];text.Text=shown;
        };return text;
    }
    static Grid Pair(FrameworkElement left, FrameworkElement right)
    {
        var grid = new Grid(); grid.ColumnDefinitions.Add(new()); grid.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        Grid.SetColumn(right, 1); grid.Children.Add(left); grid.Children.Add(right); return grid;
    }
    void MeterRow(StackPanel panel, string title, Meter? meter, bool front)
    {
        var fg = B(front ? "InkText" : "Text"); var muted = B(front ? "InkMuted" : "Muted");
        var tint = meter?.Remaining < 10 ? B("Alarm") : meter?.Remaining < 30 ? B("Warn") : fg;
        if (front)
        {
            var time = meter?.Reset - DateTimeOffset.Now;
            string reset = time is { TotalSeconds: > 0 } t ? (t.Days > 0 ? $"{t.Days} 天 {t.Hours} 小时" : t.Hours > 0 ? $"{t.Hours} 小时 {t.Minutes} 分" : $"{Math.Max(1,(int)Math.Ceiling(t.TotalMinutes))} 分钟") + (meter!.Remaining<=0?"后恢复":"后重置") : "";
            var percent = Strong(meter == null ? "—" : meter.Remaining.ToString("0") + "%", 13, tint);
            var numbers = new StackPanel { Orientation = Orientation.Horizontal };
            if (meter?.Left is { } money) { var l = Label("$" + (Math.Floor(money*100)/100).ToString("N2"), 11.5, muted); l.Margin = new(0, 1, 8, 0); numbers.Children.Add(l); }
            numbers.Children.Add(percent);
            var labels=new StackPanel{Orientation=Orientation.Horizontal};var caption=Label(title,11,muted);caption.Width=42;labels.Children.Add(caption);labels.Children.Add(Label(reset,11,meter?.Remaining<=0?B("Alarm"):muted));var row=Pair(labels,numbers); row.Margin = new(0, front && title == "5 小时" ? 20 : 10, 0, 6); panel.Children.Add(row);
        }
        var hint = meter == null ? "额度读取中" : $"{title}  剩余 {meter.Remaining:0}%"+(meter.Left is double left?$"  ${Math.Floor(left*100)/100:N2}":"")+(meter.Reset is {} r?$"  {r.LocalDateTime:g} 恢复":"");
        if(!front && meter?.Remaining<=0){var line=new Border{Background=B("Alarm"),Height=1,Opacity=.45,VerticalAlignment=VerticalAlignment.Center,ToolTip=hint};
            if(title=="5 小时" && meter.Reset is {} recovery) panel.Children.Add(Pair(line,Label(Recovery(recovery),11,B("Alarm"))));else panel.Children.Add(line);return;}
        var cells = new System.Windows.Controls.Primitives.UniformGrid { Rows = 1, Columns = 20, Margin = new(0, front ? 0 : title=="5 小时"?12:5, -3, 0) };
        var lit = (int)Math.Round((meter?.Remaining ?? 0) / 5, MidpointRounding.AwayFromZero);
        for (int i = 0; i < 20; i++) cells.Children.Add(new Border { Height = front ? 14 : 7, CornerRadius = new(front?2.5:1.5), Background = i < lit ? tint : fg, Opacity = i < lit ? (front?1:.85) : .1, Margin = new(0, 0, 3, 0) });
        cells.ToolTip = hint; panel.Children.Add(cells);
    }
    static string Recovery(DateTimeOffset time) => time.LocalDateTime.ToString(time-DateTimeOffset.Now>=TimeSpan.FromDays(1)?"M月d日 恢复":"HH:mm 恢复");
    void DrawCard(Profile p, bool front)
    {
        var panel = new StackPanel(); var reading = readings.GetValueOrDefault(p.Id) ?? new Reading(Note: "正在读取额度…");
        var fg = B(front ? "InkText" : "Text"); var title = new StackPanel();
        var status = front ? "  使用中" : "";
        title.Children.Add(Label((p.Official ? "ChatGPT" : p.SiteAccess != null ? "Lazymice" : "中转") + status, 11, B(front ? "InkMuted" : "Muted")));
        title.Children.Add(ShortName(p.Name, front ? 16 : 14, fg)); var side = new StackPanel { HorizontalAlignment = HorizontalAlignment.Right };
        var amount = reading.Balance is { } value ? "¥" + (decimal.Floor(value*100)/100).ToString("N2") : "—";
        var exhausted = new[]{reading.Five,reading.Week}.Where(m=>m?.Remaining<=0).Select(m=>m!.Reset).Max();
        if(front && exhausted is {} reset) side.Children.Add(new Border{CornerRadius=new(12),Padding=new(9,2,9,2),Background=Brush("#28E5484D"),Child=Label(Recovery(reset),11,B("Alarm"))});
        else if (front && reading.Plan != null) side.Children.Add(new Border { CornerRadius = new(12), BorderThickness = new(1), BorderBrush = B("InkMuted"), Padding = new(9, 2, 9, 2), Child = Label(reading.Plan, 11, fg) });
        if (!front)
        {
            if (reading.Balance.HasValue) side.Children.Add(Strong(amount, 16, fg));
            else if(reading.Note!=null){var info=Label(reading.Note,11.5,B("Muted"));info.MaxWidth=160;side.Children.Add(info);}
            var button = Btn("切换", async () => await Guard(() => Switch(p))); button.Foreground = B("Link"); button.Padding = new(2, 1, 0, 0); button.HorizontalAlignment = HorizontalAlignment.Right; button.FontWeight = FontWeights.SemiBold; side.Children.Add(button);
        }
        panel.Children.Add(Pair(title, side));
        if (p.Official || reading.Five != null || reading.Week != null)
        {
            if (p.Official || reading.Five != null) MeterRow(panel, "5 小时", reading.Five, front);
            if (p.Official || reading.Week != null) MeterRow(panel, "7 天", reading.Week, front);
            if (front && reading.Credits != null) { var credits = Pair(Label("Credits", 11.5, B("InkMuted")), Strong(reading.Credits, 12, fg)); credits.Margin = new(0, 16, 0, 0); panel.Children.Add(credits); }
        }
        else if (front && reading.Balance.HasValue) { var balance=Strong(amount,30,fg);panel.Children.Add(new Viewbox{Child=balance,Height=40,StretchDirection=StretchDirection.DownOnly,HorizontalAlignment=HorizontalAlignment.Right,Margin=new(0,26,0,0)}); }
        if(front && Daily(p) is {Count:>0} days) Bars(panel,Enumerable.Range(0,30).Select(i=>days.GetValueOrDefault(Today.AddDays(i-29))).ToArray(),p.Official?"$":"¥");
        if(reading.Note!=null && (front || reading.Balance.HasValue)){var note=Label(reading.Note,11,B(front?"Warn":"Muted"));note.Margin=new(0,10,0,0);panel.Children.Add(note);}
        var index = Cards.Children.Count;
        var card = new Border
        {
            CornerRadius = new(18),
            Background = B(front ? "Ink" : index % 2 == 1 ? "Back" : "BackDeep"),
            Padding = new(18, index == 0 ? 18 : 24, 18, front ? 18 : 14),
            Child = panel,
            Margin = new(0, index == 0 ? 0 : -10, 0, 0),
            Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = front?15:8, ShadowDepth = front?8:4, Opacity = front ? .22 : .07, Direction = 270 }
        };

        var menu=new ContextMenu();
        if(!front || p.Client=="Codex")Menu(menu,front?"重新应用当前配置":"切换",async()=>await Guard(()=>Switch(p)));
        if(p.SiteAccess!=null){
            Menu(menu,"使用记录…",async()=>await Guard(async()=>MessageBox.Show(this,await site.Records(p),"最近 50 条使用记录")));
            Menu(menu,"重新登录…",async()=>await Guard(async()=>{
                var dialog=new SiteDialog(this,site);if(dialog.ShowDialog()!=true || dialog.Result is not {} updated)return;
                if(updated.SiteKey!=p.SiteKey){Toast("登录账号与当前卡片不一致");return;}
                var replacement=updated with{Id=p.Id,Name=p.Name,Ratio=p.Ratio};state.Cards[state.Cards.IndexOf(p)]=replacement;Save();
                if(front)await Switch(replacement);await RefreshCard(replacement);
            }));
        }
        if(!p.Official)Menu(menu,"编辑…",()=>Edit(p));
        if(p.Client=="Codex")Menu(menu,"重命名…",()=>{var dialog=new EditDialog(this,p.Client,p,true);if(dialog.ShowDialog()==true && dialog.Value is {} value){state.Cards[state.Cards.IndexOf(p)]=value;Save();Render();}});
        Menu(menu,p.Official?"刷新额度":"刷新余额",async()=>await Guard(()=>RefreshCard(p)));
        menu.Items.Add(new Separator());Menu(menu,"删除…",()=>Delete(p));((MenuItem)menu.Items[^1]).IsEnabled=!front;card.ContextMenu=menu;
        Panel.SetZIndex(card, 10000 - Cards.Children.Count); Cards.Children.Add(card);
    }

}
