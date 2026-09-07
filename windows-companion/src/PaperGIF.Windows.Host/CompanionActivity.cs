namespace PaperGIF.Windows.Host;

internal sealed class CompanionActivity
{
    private readonly object gate = new();
    private ActionSnapshot? lastAction;
    private readonly List<ActionSnapshot> recentActions = [];

    public ActionSnapshot? LastAction
    {
        get
        {
            lock (gate)
            {
                return lastAction;
            }
        }
    }

    public IReadOnlyList<ActionSnapshot> RecentActions
    {
        get
        {
            lock (gate)
            {
                return recentActions.ToArray();
            }
        }
    }

    public event EventHandler<ActionSnapshot>? ActionRecorded;

    public void Record(RemoteRequest request, RemoteActionResult result)
    {
        var snapshot = new ActionSnapshot(
            request.Type,
            request.Text,
            result.Succeeded,
            result.Changed,
            DateTimeOffset.UtcNow);
        lock (gate)
        {
            lastAction = snapshot;
            recentActions.Insert(0, snapshot);
            if (recentActions.Count > 25)
            {
                recentActions.RemoveAt(recentActions.Count - 1);
            }
        }
        ActionRecorded?.Invoke(this, snapshot);
    }
}

internal sealed record ActionSnapshot(
    string Type,
    string Text,
    bool Succeeded,
    bool Changed,
    DateTimeOffset ReceivedAt);