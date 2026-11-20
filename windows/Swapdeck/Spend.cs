namespace Swapdeck;

public sealed class Spend
{
    public decimal? Balance { get; set; }
    public Dictionary<DateOnly, decimal> Daily { get; set; } = [];
    public void Observe(decimal balance, DateOnly day)
    {
        decimal spend = Daily.GetValueOrDefault(day);
        if (Balance is decimal previous) spend = Math.Max(0, spend + previous - balance);
        Daily[day] = spend; Balance = balance;
    }
}
public sealed class SpendBook(Paths paths)
{
    string FileName => Path.Combine(paths.Data, "spend.json");
    public Dictionary<Guid, Spend> Cards { get; } = Files.Read(Path.Combine(paths.Data, "spend.json")) is { } bytes ? JsonSerializer.Deserialize<Dictionary<Guid, Spend>>(bytes)! : [];
    public void Record(Profile profile, Reading reading)
    {
        if (!Cards.TryGetValue(profile.Id, out var spend)) Cards.Add(profile.Id, spend = new());
        if (reading.Balance is decimal balance) spend.Observe(balance, DateOnly.FromDateTime(DateTime.Today));
        if (reading.Daily != null) foreach (var (date, cost) in reading.Daily) spend.Daily[date] = cost;
        Files.Write(FileName, Files.Json(Cards));
    }
}
