using System.Windows.Forms;

namespace PaperGIF.Windows.Host;

internal sealed class PairingApprovalService(CompanionConfiguration configuration)
{
    private readonly SemaphoreSlim promptGate = new(1, 1);

    public event EventHandler? PairingChanged;
    public event EventHandler<string>? ApprovalRequested;

    public string ForgetAll()
    {
        var previousToken = configuration.Token;
        configuration.Token = Guid.NewGuid().ToString();
        configuration.PairedDevices.Clear();
        configuration.Save();
        PairingChanged?.Invoke(this, EventArgs.Empty);
        return previousToken;
    }

    public bool RequestApproval(string deviceName)
    {
        if (!promptGate.Wait(0))
        {
            return false;
        }

        try
        {
            var requester = deviceName.Trim();
            var displayName = string.IsNullOrEmpty(requester) ? "an iPhone" : requester;
            ApprovalRequested?.Invoke(this, displayName);
            var approved = ShowTopMostPrompt(
                $"Approve only if you initiated pairing in paperGIF.\n\n" +
                $"{displayName} will be able to run configured remote actions on this PC.",
                $"Pair with {displayName}?");
            if (!approved)
            {
                return false;
            }

            if (!string.IsNullOrEmpty(requester) &&
                !configuration.PairedDevices.Contains(requester, StringComparer.Ordinal))
            {
                configuration.PairedDevices.Add(requester);
                configuration.Save();
                PairingChanged?.Invoke(this, EventArgs.Empty);
            }
            return true;
        }
        finally
        {
            promptGate.Release();
        }
    }

    // Requests arrive on web-server threads with no window, so an unowned MessageBox stays hidden behind other apps.
    private static bool ShowTopMostPrompt(string text, string caption)
    {
        var result = DialogResult.No;
        var thread = new Thread(() =>
        {
            using var owner = new Form
            {
                FormBorderStyle = FormBorderStyle.None,
                Opacity = 0,
                ShowInTaskbar = false,
                Size = new System.Drawing.Size(1, 1),
                StartPosition = FormStartPosition.CenterScreen,
                TopMost = true,
            };
            owner.Show();
            owner.Activate();
            result = MessageBox.Show(
                owner,
                text,
                caption,
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Information,
                MessageBoxDefaultButton.Button1);
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.IsBackground = true;
        thread.Start();
        thread.Join();
        return result == DialogResult.Yes;
    }
}