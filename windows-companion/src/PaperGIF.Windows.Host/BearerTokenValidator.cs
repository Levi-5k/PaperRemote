using System.Security.Cryptography;
using System.Text;

namespace PaperGIF.Windows.Host;

internal static class BearerTokenValidator
{
    public static bool IsAuthorized(string? authorization, string expectedToken)
    {
        const string prefix = "Bearer ";
        if (authorization is null ||
            !authorization.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        var suppliedBytes = Encoding.UTF8.GetBytes(authorization[prefix.Length..]);
        var expectedBytes = Encoding.UTF8.GetBytes(expectedToken);
        return suppliedBytes.Length == expectedBytes.Length &&
            CryptographicOperations.FixedTimeEquals(suppliedBytes, expectedBytes);
    }
}