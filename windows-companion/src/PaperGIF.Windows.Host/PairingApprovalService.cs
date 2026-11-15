using System.Windows.Forms;

namespace PaperGIF.Windows.Host;

internal enum PairingApprovalResult { Approved, Declined, Busy, Expired }

internal sealed class PairingApprovalService(
    CompanionConfiguration configuration,
    Func<string, string, CancellationToken, Task<bool>>? showPrompt = null,
    TimeSpan? approvalTimeout = null)
{
    private readonly SemaphoreSlim promptGate = new(1, 1);
    private Form? promptOwner;

    public event EventHandler? PairingChanged;
    public event EventHandler<string>? ApprovalRequested;

    public void AttachPromptOwner(Form owner)
    {
        _ = owner.Handle;
        promptOwner = owner;
    }

    public string ForgetAll()
    {
        var previousToken = configuration.Token;
        configuration.Token = Guid.NewGuid().ToString();
        configuration.PairedDevices.Clear();
        configuration.Save();
        PairingChanged?.Invoke(this, EventArgs.Empty);
        return previousToken;
    }

    public async Task<PairingApprovalResult> RequestApprovalAsync(string deviceName, CancellationToken cancellationToken = default)
    {
        if (!promptGate.Wait(0))
        {
            return PairingApprovalResult.Busy;
        }

        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(approvalTimeout ?? TimeSpan.FromSeconds(60));
        try
        {
            deadline.Token.ThrowIfCancellationRequested();
            var requester = deviceName?.Trim() ?? "";
            var displayName = string.IsNullOrEmpty(requester) ? "an iPhone" : requester;
            ApprovalRequested?.Invoke(this, displayName);
            var approved = await (showPrompt ?? ShowTopMostPromptAsync)(
                $"Approve only if you initiated pairing in OP Remote.\n\n" +
                $"{displayName} will be able to run configured remote actions on this PC.",
                $"Pair with {displayName}?", deadline.Token).WaitAsync(deadline.Token);
            deadline.Token.ThrowIfCancellationRequested();
            if (!approved)
            {
                return PairingApprovalResult.Declined;
            }

            if (!string.IsNullOrEmpty(requester) &&
                !configuration.PairedDevices.Contains(requester, StringComparer.Ordinal))
            {
                configuration.PairedDevices.Add(requester);
                configuration.Save();
                PairingChanged?.Invoke(this, EventArgs.Empty);
            }
            return PairingApprovalResult.Approved;
        }
        catch (OperationCanceledException) when (deadline.IsCancellationRequested)
        {
            return PairingApprovalResult.Expired;
        }
        finally
        {
            promptGate.Release();
        }
    }

    private Task<bool> ShowTopMostPromptAsync(string text, string caption, CancellationToken cancellationToken)
    {
        var completion = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        void ShowPrompt(Form? owner)
        {
            try
            {
                cancellationToken.ThrowIfCancellationRequested();
                using var prompt = new Form
                {
                    Text = caption,
                    FormBorderStyle = FormBorderStyle.FixedDialog,
                    ClientSize = new System.Drawing.Size(440, 190),
                    StartPosition = owner is null ? FormStartPosition.CenterScreen : FormStartPosition.CenterParent,
                    Owner = owner,
                    TopMost = true,
                    ShowInTaskbar = true,
                    MinimizeBox = false,
                    MaximizeBox = false,
                    AutoScaleMode = AutoScaleMode.Dpi,
                };
                var message = new Label { Text = text, Dock = DockStyle.Fill, Padding = new Padding(20) };
                var buttons = new FlowLayoutPanel
                {
                    Dock = DockStyle.Bottom,
                    Height = 54,
                    Padding = new Padding(10),
                    FlowDirection = FlowDirection.RightToLeft,
                };
                var decline = new Button { Text = "Decline", DialogResult = DialogResult.Cancel, AutoSize = true, Height = 32 };
                var approve = new Button { Text = "Pair", DialogResult = DialogResult.OK, AutoSize = true, Height = 32 };
                buttons.Controls.Add(decline);
                buttons.Controls.Add(approve);
                prompt.Controls.Add(message);
                prompt.Controls.Add(buttons);
                prompt.AcceptButton = approve;
                prompt.CancelButton = decline;
                using var timer = new System.Windows.Forms.Timer { Interval = 100 };
                timer.Tick += (_, _) =>
                {
                    if (cancellationToken.IsCancellationRequested) prompt.DialogResult = DialogResult.Cancel;
                };
                prompt.Shown += (_, _) => { timer.Start(); prompt.Activate(); };
                var result = owner is null ? prompt.ShowDialog() : prompt.ShowDialog(owner);
                var approved = result == DialogResult.OK && !cancellationToken.IsCancellationRequested;
                completion.TrySetResult(approved);
            }
            catch (OperationCanceledException)
            {
                completion.TrySetCanceled(cancellationToken);
            }
            catch (Exception exception)
            {
                completion.TrySetException(exception);
            }
        }
        var owner = promptOwner;
        if (owner is { IsDisposed: false, IsHandleCreated: true })
        {
            owner.BeginInvoke(() => ShowPrompt(owner.Visible ? owner : null));
            return completion.Task;
        }
        var thread = new Thread(() => ShowPrompt(null));
        thread.SetApartmentState(ApartmentState.STA);
        thread.IsBackground = true;
        thread.Start();
        return completion.Task;
    }
}