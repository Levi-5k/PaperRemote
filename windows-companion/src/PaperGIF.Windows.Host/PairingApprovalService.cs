using System.Windows.Forms;

namespace PaperGIF.Windows.Host;

internal sealed class PairingApprovalService(CompanionConfiguration configuration)
{
    private readonly SemaphoreSlim promptGate = new(1, 1);

    public event EventHandler? PairingChanged;

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
            var result = MessageBox.Show(
                $"Approve only if you initiated pairing in paperGIF.\n\n" +
                $"{displayName} will be able to run configured remote actions on this PC.",
                $"Pair with {displayName}?",
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Information,
                MessageBoxDefaultButton.Button1);
            if (result != DialogResult.Yes)
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
}