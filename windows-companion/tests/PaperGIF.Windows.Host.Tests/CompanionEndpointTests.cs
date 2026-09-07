using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;
using PaperGIF.Windows.Host;
using Xunit;

namespace PaperGIF.Windows.Host.Tests;

public sealed class CompanionEndpointTests
{
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
    public async Task TextSourceRejectsMoreThanSixteenItems()
    {
        await using var host = await TestHost.StartAsync();
        var items = Enumerable.Range(0, 17).Select(index => new
        {
            id = index.ToString(),
            source = "unsupported",
            sourceText = "",
            placeholder = "",
        });

        var response = await host.Client.PostAsJsonAsync("/text-source", new { items });

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
    }

    private sealed class TestHost(WebApplication app, HttpClient client) : IAsyncDisposable
    {
        public HttpClient Client { get; } = client;

        public static async Task<TestHost> StartAsync()
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
            builder.Services.AddSingleton<PairingApprovalService>();
            builder.Services.AddSingleton<WindowsActionDispatcher>();
            builder.Services.AddSingleton<WindowsTextSourceResolver>();
            builder.Services.AddSingleton<WindowsApplicationCatalog>();
            builder.Services.AddSingleton<NetHomeService>();
            var app = builder.Build();
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