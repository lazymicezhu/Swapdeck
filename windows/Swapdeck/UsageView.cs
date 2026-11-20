using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
namespace Swapdeck;

public partial class MainWindow
{
    int period = 30;
    string scope = "全部";
    static readonly string[] LightColors = ["#2F6BFF","#E8915B","#46A07A","#9B7BE0","#D9608F","#2E9FB0"];
    static readonly string[] DarkColors = ["#5B8CFF","#F0A06A","#5BBE90","#B095F0","#E97AA5","#4EC0CF"];
    bool night;
    Brush Accent(int i) => i < 0 ? B("InkMuted") : Brush((night ? DarkColors : LightColors)[i % LightColors.Length]);
    static DateOnly Today => DateOnly.FromDateTime(DateTime.Today);
    static string DateLabel(DateOnly d) => d == Today ? "今天" : d == Today.AddDays(-1) ? "昨天" : $"{d:M月d日} 周{"日一二三四五六"[(int)d.DayOfWeek]}";
    static string Money(double value) => "¥" + value.ToString("N2");
    static string Count(double v) => v >= 1e8 ? (v/1e8).ToString("N2")+" 亿" : v>=1e4 ? (v/1e4).ToString("N0")+" 万" : v.ToString("N0");
    Dictionary<DateOnly,double> Daily(Profile p)
    {
        if (!p.Official) return spend.Cards.TryGetValue(p.Id,out var h) ? h.Daily.ToDictionary(x=>x.Key,x=>(double)x.Value) : [];
        var id=JsonNode.Parse(p.Secret)?["tokens"]?["account_id"]?.ToString();
        return id!=null && usage.Accounts.TryGetValue(id,out var days) ? days : [];
    }
    void Bars(StackPanel panel, double[] days, string unit)
    {
        var grid=new UniformGrid { Rows=1,Height=38,Margin=new(0,18,0,5) };
        var summary=new UniformGrid {Rows=1,Columns=3,Height=16};
        foreach(var (label,sum) in new[]{("今日",days[^1]),("7 天",days.TakeLast(7).Sum()),("30 天",days.Sum())}){
            var text=Label(label+" ",11,B("InkMuted")); text.Inlines.Add(new System.Windows.Documents.Run(unit+sum.ToString("N2")){FontWeight=FontWeights.SemiBold,Foreground=B("InkText")});
            text.TextAlignment=summary.Children.Count switch {0=>TextAlignment.Left,1=>TextAlignment.Center,_=>TextAlignment.Right};
            summary.Children.Add(text);
        }
        var detail=Label("",11,B("InkText")); var footer=new Grid{Height=16}; footer.Children.Add(summary);footer.Children.Add(detail);
        double peak=Math.Max(.000001,days.Max());
        void Highlight(int index){
            for(int i=0;i<grid.Children.Count;i++)grid.Children[i].Opacity=index<0?(i==29?1:i>=23?.55:.22):i==index?1:.16;
            summary.Visibility=index<0?Visibility.Visible:Visibility.Hidden;
            detail.Text=index<0?"":DateLabel(Today.AddDays(index-29))+"   "+unit+days[index].ToString("N2");
        }
        for(int i=0;i<days.Length;i++){
            int index=i;var hit=new Grid{Background=Brushes.Transparent};
            hit.Children.Add(new Border{Height=Math.Clamp(38*days[i]/peak,2,38),VerticalAlignment=VerticalAlignment.Bottom,Margin=new(0,0,2,0),CornerRadius=new(1.5),Background=B("InkText")});
            hit.MouseEnter+=(_,_)=>Highlight(index);grid.Children.Add(hit);
        }
        Highlight(-1);grid.MouseLeave+=(_,_)=>Highlight(-1);panel.Children.Add(grid);panel.Children.Add(footer);
    }

    sealed record Slice(string Name,string Kind,double Value,int Color);
    void Breakdown(StackPanel panel,Slice[] parts,bool spendChart,string? center,string empty)
    {
        var fg=B(spendChart?"InkText":"Text");var muted=B(spendChart?"InkMuted":"Muted");
        var grid=new Grid{Height=spendChart?108:98,Margin=new(0,spendChart?14:6,0,0)};
        grid.ColumnDefinitions.Add(new(){Width=new(92)});grid.ColumnDefinitions.Add(new());
        var ring=new Grid{Width=92,Height=92,VerticalAlignment=VerticalAlignment.Center};grid.Children.Add(ring);
        double pen=spendChart?11:10;ring.Children.Add(new System.Windows.Shapes.Ellipse{Stroke=fg,Opacity=.06,StrokeThickness=pen});
        double sum=parts.Sum(p=>p.Value),at=0;
        foreach(var item in parts.Where(p=>p.Value>0)){
            double share=item.Value/sum;
            ring.Children.Add(new System.Windows.Shapes.Ellipse{Stroke=Accent(item.Color),StrokeThickness=pen,
                RenderTransformOrigin=new(.5,.5),RenderTransform=new RotateTransform(-90+360*at),
                StrokeDashArray=new DoubleCollection{Math.Max(.015,Math.PI*(92-pen)/pen*share-(share<1?.12:0)),100}});
            at+=share;
        }
        if(center!=null){var info=new StackPanel{VerticalAlignment=VerticalAlignment.Center,HorizontalAlignment=HorizontalAlignment.Center};
            var value=Strong(center,18,fg);value.TextAlignment=TextAlignment.Center;info.Children.Add(value);info.Children.Add(Label("缓存命中",10,muted));ring.Children.Add(info);}
        var list=new StackPanel{VerticalAlignment=VerticalAlignment.Center,Margin=new(16,0,0,0)};Grid.SetColumn(list,1);grid.Children.Add(list);
        if(parts.Length==0)list.Children.Add(Label(empty,12,muted));
        foreach(var item in parts){
            var name=new DockPanel();name.Children.Add(new Border{Width=7,Height=7,CornerRadius=new(2),Background=Accent(item.Color),Margin=new(0,0,7,0)});
            var title=ShortName(item.Name,12,fg);title.FontWeight=FontWeights.Normal;title.TextWrapping=TextWrapping.NoWrap;title.TextTrimming=TextTrimming.CharacterEllipsis;title.ToolTip=item.Name;
            if(item.Kind.Length>0){var kind=Label(item.Kind,10.5,muted);kind.Margin=new(4,0,5,0);DockPanel.SetDock(kind,Dock.Right);name.Children.Add(kind);}name.Children.Add(title);
            var row=Pair(name,Strong(spendChart?Money(item.Value):Count(item.Value),12,fg));row.Height=16;
            if(list.Children.Count>0)row.Margin=new(0,7,0,0);list.Children.Add(row);
        }
        panel.Children.Add(grid);
    }
    StackPanel Section(bool front){
        var panel=new StackPanel();
        Cards.Children.Add(new Border{Child=panel,Padding=front?new Thickness(18):new Thickness(16,14,16,14),Background=B(front?"Ink":"Back"),CornerRadius=new(front?20:16),Margin=new(0,0,0,12)});
        return panel;
    }
    void RenderUsage()
    {
        var today=Today;
        var lines=state.Cards.Select((p,i)=>(Profile:p,Color:i,Days:Daily(p))).Where(l=>scope=="全部"||scope==l.Profile.Client).ToArray();
        var oldest=lines.SelectMany(l=>l.Days.Where(d=>d.Value>0).Select(d=>d.Key)).DefaultIfEmpty(today).Min();
        var first=period==0?DateOnly.MinValue:today.AddDays(1-period);
        string range=period switch {0=>"全部",1=>"今日",_=>period+" 天"};
        double[] Totals(DateOnly start,DateOnly end)=>lines.Select(l=>l.Days.Where(x=>x.Key>=start&&x.Key<=end).Sum(x=>x.Value)).ToArray();
        var totals=Totals(first,today);
        var top=Section(true);var header=new StackPanel();top.Children.Add(header);
        void Header(string title,double[] values,string empty){
            header.Children.Clear();header.Children.Add(Label(title,11,B("InkMuted")));
            var amount=Strong("¥",16,B("InkMuted"));amount.Height=40;
            amount.Inlines.Add(new System.Windows.Documents.Run(values.Sum().ToString("N2")){FontSize=30,Foreground=B("InkText")});header.Children.Add(amount);
            var sides=lines.Select((l,i)=>(l.Profile.Client,Value:values[i])).GroupBy(l=>l.Client).Select(g=>g.Key+" "+Money(g.Sum(v=>v.Value)));
            var sub=Label(string.Join(" · ",sides),11.5,B("InkMuted"));sub.Height=17;header.Children.Add(sub);
            var parts=lines.Select((l,i)=>new Slice(l.Profile.Name,l.Profile.Official?"订阅":"中转",values[i],l.Color)).Where(v=>v.Value>0).ToArray();
            if(parts.Length>5)parts=[..parts.Take(4),new("其他 "+(parts.Length-4)+" 个","",parts.Skip(4).Sum(x=>x.Value),-1)];
            Breakdown(header,parts,true,null,empty);
        }
        string normal=period==0?$"累计花费 · {oldest:yyyy年M月d日} 起":range+"花费";
        Header(normal,totals,"这段时间没有花费");
        var start=period==0?oldest:today.AddDays(-29);
        bool monthly=period==0 && today.DayNumber-oldest.DayNumber>=420;
        if(period==0)start=monthly?new(start.Year,start.Month,1):start.AddDays(-((int)start.DayOfWeek+6)%7);
        DateOnly Next(DateOnly d)=>period!=0?d.AddDays(1):monthly?d.AddMonths(1):d.AddDays(7);
        var buckets=new List<(DateOnly Day,double[] Values)>();
        for(var day=start;day<=today;day=Next(day)) buckets.Add((day,Totals(day,Next(day).AddDays(-1))));
        var peak=Math.Max(.000001,buckets.Max(b=>b.Values.Sum()));
        var chart=new UniformGrid{Rows=1,Columns=buckets.Count,Height=60,Margin=new(0,16,0,7)};
        void Dim(int active){for(int i=0;i<chart.Children.Count;i++)chart.Children[i].Opacity=active<0?(buckets[i].Day>=first?1:.35):active==i?1:.3;}
        for(int i=0;i<buckets.Count;i++){
            int index=i;var (day,values)=buckets[i];var hit=new Grid{Background=Brushes.Transparent};
            var stack=new StackPanel{VerticalAlignment=VerticalAlignment.Bottom,Margin=new(0,0,buckets.Count>45?1.5:2.5,0)};
            for(int k=lines.Length-1;k>=0;k--)if(values[k]>0)stack.Children.Add(new Border{Height=60*values[k]/peak,Background=Accent(lines[k].Color),CornerRadius=new(1.5)});
            if(stack.Children.Count==0)stack.Children.Add(new Border{Height=2,Background=B("InkText"),Opacity=.12});
            hit.Children.Add(stack);chart.Children.Add(hit);
            hit.MouseEnter+=(_,_)=>{string label=period!=0?DateLabel(day):monthly?day.ToString("yyyy年M月"):$"{day:M月d日}–{Next(day).AddDays(-1):M月d日}";
                Header(label+" 花费",values,period!=0?"这天没有花费":monthly?"这个月没有花费":"这周没有花费");Dim(index);};
        }
        chart.MouseLeave+=(_,_)=>{Header(normal,totals,"这段时间没有花费");Dim(-1);};Dim(-1);top.Children.Add(chart);
        var axis=new Grid();foreach(var (label,align) in new[]{(DateLabel(start),HorizontalAlignment.Left),(DateLabel(buckets[(buckets.Count-1)/2].Day),HorizontalAlignment.Center),(period!=0?"今天":monthly?"本月":"本周",HorizontalAlignment.Right)}){
            if(buckets.Count<3 && align==HorizontalAlignment.Center) continue;
            var tick=Label(label,10.5,B("InkMuted"));tick.HorizontalAlignment=align;axis.Children.Add(tick);}
        top.Children.Add(axis);UsageFilters();
        var visible=usage.Rows.Where(x=>(scope=="全部"||x.Key.Client==scope)&&x.Key.Date>=first&&x.Key.Date<=today).ToArray();
        var allocations=new Dictionary<string,double>();
        foreach(var side in visible.GroupBy(x=>x.Key.Client)){
            double cost=side.Sum(x=>x.Value.Cost), actual=lines.Select((l,i)=>l.Profile.Client==side.Key?totals[i]:0).Sum();
            if(cost<=0 || actual<=0)continue;
            foreach(var g in side.GroupBy(x=>x.Key.Model))allocations[g.Key]=allocations.GetValueOrDefault(g.Key)+actual*g.Sum(x=>x.Value.Cost)/cost;
        }
        var models=Section(false);models.Children.Add(Pair(Strong("模型",12.5,B("Text")),Label(range,11,B("Muted"))));
        var groups=allocations.Where(k=>k.Value>0).OrderByDescending(k=>k.Value).Select(k=>(Name:k.Key,k.Value)).ToArray();
        if(groups.Length>4)groups=[..groups.Take(3),("其他 "+(groups.Length-3)+" 个",groups.Skip(3).Sum(x=>x.Value))];
        var area=new Grid{Height=158,Margin=new(0,6,0,0)};models.Children.Add(area);var rows=new StackPanel();area.Children.Add(rows);
        if(groups.Length==0){var empty=Label("没有记录",12,B("Muted"));empty.VerticalAlignment=VerticalAlignment.Center;empty.HorizontalAlignment=HorizontalAlignment.Center;area.Children.Add(empty);}
        foreach(var item in groups){
            double share=item.Value/Math.Max(.000001,allocations.Values.Sum());var row=Pair(Strong(item.Name,12.5,B("Text")),Label(Money(item.Value)+"    "+(share<.005?"<1%":share.ToString("P0")),11.5,B("Muted")));
            row.Margin=new(0,7,0,5);rows.Children.Add(row);
            var bar=new Grid{Height=4,Background=B("BackDeep")};bar.ColumnDefinitions.Add(new(){Width=new(share,GridUnitType.Star)});bar.ColumnDefinitions.Add(new(){Width=new(Math.Max(0,1-share),GridUnitType.Star)});
            bar.Children.Add(new Border{CornerRadius=new(2),Background=B("Text"),Opacity=.8});rows.Children.Add(bar);
            if(item!=groups[^1])rows.Children.Add(new Border{Height=1,Background=B("Text"),Opacity=.07,Margin=new(0,5,0,0)});
        }
        var tokens=Section(false);var sumTokens=visible.Select(x=>x.Value).Aggregate(new DayUsage(0,0,0,0),(a,b)=>a+b);
        double denominator=sumTokens.Cached+sumTokens.Written+sumTokens.Input,total=denominator+sumTokens.Output;
        tokens.Children.Add(Pair(Strong("Token",12.5,B("Text")),Label(range+(total>0?" · "+Count(total):""),11,B("Muted"))));
        Breakdown(tokens,[new("缓存读取","",sumTokens.Cached,0),new("缓存写入","",sumTokens.Written,1),new("输出","",sumTokens.Output,2),new("输入","",sumTokens.Input,3)],false,denominator>0?(sumTokens.Cached/denominator).ToString("P0"):"—","");
    }
    DateTime lastThirtyClick;
    void UsageFilters(){
        var filters=new UniformGrid{Rows=1,Columns=2,Margin=new(0,0,0,12)};Cards.Children.Add(filters);
        for(int set=0;set<2;set++){
            bool time=set==1;var group=new UniformGrid{Columns=3,Rows=1};filters.Children.Add(new Border{Child=group,Padding=new(2),Background=B("BackDeep"),CornerRadius=new(14),Margin=time?new(5,0,0,0):new(0,0,5,0)});
            var names=time?new[]{"今日","7 天",period==0?"全部":"30 天"}:new[]{"全部","Claude","Codex"};
            for(int i=0;i<3;i++){
                int index=i,d=new[]{1,7,30}[i];string s=names[i];var b=Btn(s,()=>{
                    if(time && index==2 && period!=0 && (DateTime.UtcNow-lastThirtyClick).TotalMilliseconds<=DoubleClickTime()) {period=0;lastThirtyClick=default;}
                    else{lastThirtyClick=time && index==2 && period!=0?DateTime.UtcNow:default;if(time)period=d;else scope=s;}
                    Render();
                });b.Padding=new(0,4,0,4);b.FontSize=11.5;
                if(time && index==2)b.ToolTip=period==0?"单击回到 30 天":"双击查看全部";
                if(time?(period==d||index==2&&period==0):scope==s){b.Background=B("Back");b.FontWeight=FontWeights.SemiBold;b.Effect=new System.Windows.Media.Effects.DropShadowEffect{BlurRadius=1,ShadowDepth=1,Direction=270,Opacity=.08};}else b.Foreground=B("Muted");
                group.Children.Add(b);
            }
        }
    }
    [System.Runtime.InteropServices.DllImport("user32.dll",EntryPoint="GetDoubleClickTime")] static extern uint DoubleClickTime();
}