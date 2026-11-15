using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;
using PaperGIF.Windows.Core.Models;
using PaperGIF.Windows.Host;
using Xunit;

namespace PaperGIF.Windows.Host.Tests;

public sealed class CompanionEndpointTests
{
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool IsWindowEnabled(IntPtr window);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern IntPtr GetWindow(IntPtr window, uint command);

    public sealed class InteractiveFactAttribute : FactAttribute
    {
        public InteractiveFactAttribute()
        {
            if (!Environment.UserInteractive) Skip = "Requires an interactive Windows desktop.";
        }
    }

    [InteractiveFact]
    public async Task PairingDialogExpiresWithoutAnEditorWindowAndCanReopen()
    {
        var service = new PairingApprovalService(new CompanionConfiguration(),
            approvalTimeout: TimeSpan.FromMilliseconds(250));
        var prompts = 0;
        service.ApprovalRequested += (_, _) => ++prompts;

        for (var attempt = 0; attempt < 2; ++attempt)
            Assert.Equal(PairingApprovalResult.Expired,
                await service.RequestApprovalAsync("Test Phone").WaitAsync(TimeSpan.FromSeconds(5)));
        Assert.Equal(2, prompts);
    }

    [Fact]
    public async Task PairingEndpointExpiresWithoutExposingCredentialsAndAllowsRetry()
    {
        var attempts = 0;
        await using var host = await TestHost.StartAsync(async (_, _, token) =>
        {
            if (++attempts == 1) await Task.Delay(Timeout.InfiniteTimeSpan, token);
            return false;
        }, TimeSpan.FromMilliseconds(100));
        host.Client.DefaultRequestHeaders.Authorization = null;

        var expired = await host.Client.PostAsJsonAsync("/pair", new { deviceName = "Test Phone" });
        Assert.Equal(HttpStatusCode.RequestTimeout, expired.StatusCode);
        var body = await expired.Content.ReadFromJsonAsync<JsonDocument>();
        Assert.False(body!.RootElement.TryGetProperty("token", out _));
        var retry = await host.Client.PostAsJsonAsync("/pair", new { deviceName = "Test Phone" });
        Assert.Equal(HttpStatusCode.Forbidden, retry.StatusCode);
        Assert.Equal(2, attempts);
    }

    [InteractiveFact]
    public async Task PairingDialogIsVisibleAndOwnedWhenCompanionWindowIsOpen()
    {
        var completion = new TaskCompletionSource<(bool Passed, string Diagnostic)>(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            using var owner = new System.Windows.Forms.Form { Text = "Pairing test companion" };
            var service = new PairingApprovalService(new CompanionConfiguration(),
                approvalTimeout: TimeSpan.FromMilliseconds(750));
            service.AttachPromptOwner(owner);
            var observedOwnedPrompt = false;
            var diagnostic = "No pairing dialog was observed.";
            using var timer = new System.Windows.Forms.Timer { Interval = 25 };
            timer.Tick += (_, _) =>
            {
                var prompt = System.Windows.Forms.Application.OpenForms.Cast<System.Windows.Forms.Form>()
                    .FirstOrDefault(form => form.Text == "Pair with Test Phone?");
                if (prompt is null) return;
                var nativeOwner = GetWindow(prompt.Handle, 4);
                var ownerEnabled = IsWindowEnabled(owner.Handle);
                diagnostic = $"Visible={prompt.Visible}; TopMost={prompt.TopMost}; NativeOwnerMatches={nativeOwner == owner.Handle}; OwnerEnabled={ownerEnabled}";
                observedOwnedPrompt |= prompt is { Visible: true, TopMost: true } &&
                    nativeOwner == owner.Handle && !ownerEnabled;
            };
            owner.Shown += async (_, _) =>
            {
                try
                {
                    timer.Start();
                    var result = await Task.Run(() => service.RequestApprovalAsync("Test Phone"))
                        .WaitAsync(TimeSpan.FromSeconds(5));
                    completion.TrySetResult((observedOwnedPrompt && result == PairingApprovalResult.Expired,
                        $"{diagnostic}; Result={result}"));
                }
                catch (Exception exception) { completion.TrySetException(exception); }
                finally { timer.Stop(); owner.Close(); }
            };
            System.Windows.Forms.Application.Run(owner);
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.IsBackground = true;
        thread.Start();
        var result = await completion.Task.WaitAsync(TimeSpan.FromSeconds(10));
        Assert.True(result.Passed, result.Diagnostic);
    }

    [Fact]
    public async Task PairingTimeoutReleasesPromptEvenWhenDispatcherDoesNotRespond()
    {
        var service = new PairingApprovalService(new CompanionConfiguration(),
            (_, _, _) => new TaskCompletionSource<bool>().Task,
            TimeSpan.FromMilliseconds(100));
        for (var attempt = 0; attempt < 2; ++attempt)
            Assert.Equal(PairingApprovalResult.Expired,
                await service.RequestApprovalAsync("Test Phone").WaitAsync(TimeSpan.FromSeconds(3)));
    }

    [Fact]
    public async Task PairingDeclineAllowsAnotherRequest()
    {
        var attempts = 0;
        var configuration = new CompanionConfiguration { PairedDevices = ["Test Phone"] };
        var service = new PairingApprovalService(configuration, (_, _, _) => Task.FromResult(++attempts == 2));

        Assert.Equal(PairingApprovalResult.Declined, await service.RequestApprovalAsync("Test Phone"));
        Assert.Equal(PairingApprovalResult.Approved, await service.RequestApprovalAsync("Test Phone"));
        Assert.Equal(2, attempts);
    }

    [Fact]
    public async Task PairingCancellationReleasesPromptForRetry()
    {
        using var cancellation = new CancellationTokenSource();
        var attempts = 0;
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var configuration = new CompanionConfiguration { PairedDevices = ["Test Phone"] };
        var service = new PairingApprovalService(configuration, async (_, _, token) =>
        {
            if (++attempts == 1)
            {
                started.SetResult();
                await Task.Delay(Timeout.InfiniteTimeSpan, token);
            }
            return true;
        });

        var first = service.RequestApprovalAsync("Test Phone", cancellation.Token);
        await started.Task.WaitAsync(TimeSpan.FromSeconds(3));
        Assert.Equal(PairingApprovalResult.Busy, await service.RequestApprovalAsync("Other Phone"));
        cancellation.Cancel();
        Assert.Equal(PairingApprovalResult.Expired, await first.WaitAsync(TimeSpan.FromSeconds(3)));
        Assert.Equal(PairingApprovalResult.Approved, await service.RequestApprovalAsync("Test Phone"));
    }

    [Fact]
    public async Task PairingTimeoutReleasesPromptForRetry()
    {
        var attempts = 0;
        var configuration = new CompanionConfiguration { PairedDevices = ["Test Phone"] };
        var service = new PairingApprovalService(configuration, async (_, _, token) =>
        {
            if (++attempts == 1) await Task.Delay(Timeout.InfiniteTimeSpan, token);
            return true;
        }, TimeSpan.FromMilliseconds(100));

        Assert.Equal(PairingApprovalResult.Expired,
            await service.RequestApprovalAsync("Test Phone").WaitAsync(TimeSpan.FromSeconds(3)));
        Assert.Equal(PairingApprovalResult.Approved, await service.RequestApprovalAsync("Test Phone"));
    }

    [Fact]
    public async Task PairingCannotApproveAfterCancellation()
    {
        using var cancellation = new CancellationTokenSource();
        var configuration = new CompanionConfiguration();
        var service = new PairingApprovalService(configuration, (_, _, _) =>
        {
            cancellation.Cancel();
            return Task.FromResult(true);
        });

        Assert.Equal(PairingApprovalResult.Expired, await service.RequestApprovalAsync("Test Phone", cancellation.Token));
        Assert.Empty(configuration.PairedDevices);
    }

    [Fact]
    public async Task StatusRequiresBearerToken()
    {
        await using var host = await TestHost.StartAsync();
        host.Client.DefaultRequestHeaders.Authorization = null;

        var response = await host.Client.GetAsync("/status");

        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
    }

    [Fact]
    public async Task StatusReportsWindowsHost()
    {
        await using var host = await TestHost.StartAsync();

        var response = await host.Client.GetAsync("/status");
        var document = await response.Content.ReadFromJsonAsync<JsonDocument>();

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("windows", document!.RootElement.GetProperty("platform").GetString());
        Assert.Equal(1, document.RootElement.GetProperty("protocolVersion").GetInt32());
    }

    [Fact]
    public async Task UnsupportedActionReturnsBadRequest()
    {
        await using var host = await TestHost.StartAsync();

        var response = await host.Client.PostAsJsonAsync("/action", new
        {
            type = "unsupported",
            text = "",
            value = 0,
            modifiers = Array.Empty<string>(),
        });

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
    }

    [Fact]
    public async Task HomeAccessoriesSharedByIPhoneAreSavedForTheEditor()
    {
        await using var host = await TestHost.StartAsync();
        var accessoryID = Guid.NewGuid().ToString();

        var response = await host.Client.PostAsJsonAsync("/home-accessories", new
        {
            accessories = new[]
            {
                new
                {
                    homeName = "Home", accessoryName = "Desk Lamp", serviceName = "Desk Lamp",
                    accessoryID, serviceID = Guid.NewGuid().ToString(), isReachable = true,
                },
            },
        });

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        var saved = Assert.Single(host.HomeAccessories.Accessories);
        Assert.Equal(accessoryID, saved.AccessoryID);
        Assert.Equal("Home · Desk Lamp", saved.DisplayName);
    }

    [Fact]
    public async Task HomeAccessoriesRejectBadListsAndMissingToken()
    {
        await using var host = await TestHost.StartAsync();

        var invalid = await host.Client.PostAsJsonAsync("/home-accessories", new
        {
            accessories = new[] { new { homeName = "Home", accessoryName = "A", serviceName = "A", accessoryID = "x", serviceID = "y" } },
        });
        host.Client.DefaultRequestHeaders.Authorization = null;
        var unauthorized = await host.Client.PostAsJsonAsync("/home-accessories", new { accessories = Array.Empty<object>() });

        Assert.Equal(HttpStatusCode.BadRequest, invalid.StatusCode);
        Assert.Equal(HttpStatusCode.Unauthorized, unauthorized.StatusCode);
        Assert.Empty(host.HomeAccessories.Accessories);
    }

    [Fact]
    public async Task ApplicationsReturnsCompatibleCatalog()
    {
        await using var host = await TestHost.StartAsync();

        var response = await host.Client.GetAsync("/applications");
        var document = await response.Content.ReadFromJsonAsync<JsonDocument>();

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal(JsonValueKind.Array, document!.RootElement.ValueKind);
        foreach (var application in document.RootElement.EnumerateArray())
        {
            Assert.Equal(JsonValueKind.String, application.GetProperty("name").ValueKind);
            Assert.Equal(JsonValueKind.String, application.GetProperty("path").ValueKind);
            Assert.True(application.TryGetProperty("iconBitmap", out _));
        }
    }

    [Fact]
    public async Task TextSourceReturnsBoundedIdAndPlaceholder()
    {
        await using var host = await TestHost.StartAsync();
        var longId = new string('a', 48);

        var response = await host.Client.PostAsJsonAsync("/text-source", new
        {
            items = new[]
            {
                new
                {
                    id = longId,
                    source = "unsupported",
                    sourceText = "",
                    placeholder = "Unavailable",
                },
            },
        });
        var document = await response.Content.ReadFromJsonAsync<JsonDocument>();
        var item = document!.RootElement.GetProperty("items")[0];

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.NotNull(response.Content.Headers.ContentLength);
        Assert.Empty(response.Headers.TransferEncoding);
        Assert.Equal(longId[..40], item.GetProperty("id").GetString());
        Assert.Equal("Unavailable", item.GetProperty("text").GetString());
        Assert.False(item.GetProperty("available").GetBoolean());
    }

    [Fact]
    public async Task AuthenticatedMediaReadSubscribesPeer()
    {
        await using var host = await TestHost.StartAsync();

        var response = await host.Client.PostAsJsonAsync("/text-source", new
        {
            items = new[] { new { id = "volume", source = "outputVolume" } },
        });

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.True(host.Publisher.HasSubscribers);
    }

    [Fact]
    public async Task UnauthorizedMediaReadCannotSubscribePeer()
    {
        await using var host = await TestHost.StartAsync();
        host.Client.DefaultRequestHeaders.Authorization = null;

        var response = await host.Client.PostAsJsonAsync("/text-source", new
        {
            items = new[] { new { id = "volume", source = "outputVolume" } },
        });

        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
        Assert.False(host.Publisher.HasSubscribers);
    }

    [Fact]
    public async Task TextSourceRejectsMoreThanMaximumItems()
    {
        await using var host = await TestHost.StartAsync();
        var items = Enumerable.Range(0, RemoteProfile.MaximumControlsPerPage + 1).Select(index => new
        {
            id = index.ToString(),
            source = "outputVolume",
            sourceText = "",
            placeholder = "",
        });

        var response = await host.Client.PostAsJsonAsync("/text-source", new { items });

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.False(host.Publisher.HasSubscribers);
    }

    private sealed class TestHost(WebApplication app, HttpClient client) : IAsyncDisposable
    {
        public HttpClient Client { get; } = client;
        public WindowsMediaUpdatePublisher Publisher => app.Services.GetRequiredService<WindowsMediaUpdatePublisher>();
        public HomeAccessoryCatalog HomeAccessories => app.Services.GetRequiredService<HomeAccessoryCatalog>();

        public static async Task<TestHost> StartAsync(
            Func<string, string, CancellationToken, Task<bool>>? showPrompt = null,
            TimeSpan? approvalTimeout = null)
        {
            var configuration = new CompanionConfiguration
            {
                Token = "test-token",
            };
            var builder = WebApplication.CreateBuilder(new WebApplicationOptions
            {
                EnvironmentName = "Testing",
            });
            builder.WebHost.UseTestServer();
            builder.Services.AddSingleton(configuration);
            builder.Services.AddSingleton<CompanionActivity>();
            builder.Services.AddSingleton(new PairingApprovalService(configuration, showPrompt, approvalTimeout));
            builder.Services.AddSingleton<WindowsActionDispatcher>();
            builder.Services.AddSingleton<WindowsTextSourceResolver>();
            builder.Services.AddSingleton(_ => new WindowsMediaUpdatePublisher(
                configuration, new HttpClient(), TimeProvider.System));
            builder.Services.AddSingleton<WindowsApplicationCatalog>();
            builder.Services.AddSingleton<NetHomeService>();
            builder.Services.AddSingleton<OpenBuildsControlService>();
            builder.Services.AddSingleton(new HomeAccessoryCatalog(
                Path.Combine(Path.GetTempPath(), $"papergif-home-{Guid.NewGuid():N}.json")));
            var app = builder.Build();
            app.Use((context, next) =>
            {
                context.Connection.RemoteIpAddress = IPAddress.Parse("192.168.50.142");
                return next(context);
            });
            Program.ConfigureEndpoints(app, configuration);
            await app.StartAsync();
            var client = app.GetTestClient();
            client.DefaultRequestHeaders.Authorization =
                new AuthenticationHeaderValue("Bearer", configuration.Token);
            return new TestHost(app, client);
        }

        public async ValueTask DisposeAsync()
        {
            Client.Dispose();
            await app.DisposeAsync();
        }
    }
}