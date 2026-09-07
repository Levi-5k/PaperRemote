using PaperGIF.Windows.Host;
using System.Text.Json;

internal static class Program
{
    [STAThread]
    private static async Task Main(string[] args)
    {
        if (args is ["--write-icon", var iconPath])
        {
            using var icon = PaperGifIcon.Create(256);
            await using var stream = File.Create(iconPath);
            icon.Save(stream);
            return;
        }
        var configuration = CompanionConfiguration.LoadOrCreate();
        var builder = WebApplication.CreateBuilder(args);
        builder.WebHost.UseUrls($"http://0.0.0.0:{configuration.Port}");
        builder.Services.AddSingleton(configuration);
        builder.Services.AddSingleton<CompanionActivity>();
        builder.Services.AddSingleton<PairingApprovalService>();
        builder.Services.AddSingleton<WindowsActionDispatcher>();
        builder.Services.AddSingleton<WindowsTextSourceResolver>();
        builder.Services.AddSingleton<WindowsApplicationCatalog>();
        builder.Services.AddSingleton<NetHomeService>();
        builder.Services.AddSingleton<StartupRegistration>();
        builder.Services.AddSingleton<RemoteEditorStore>();
        builder.Services.AddSingleton<NetworkDiscoveryService>();
        builder.Services.AddSingleton<ModuleCatalogService>();

        await using var app = builder.Build();
        ConfigureEndpoints(app, configuration);
        await app.StartAsync();
        using var bonjourAdvertiser = new BonjourAdvertiser(configuration.Port);

        System.Windows.Forms.Application.SetHighDpiMode(HighDpiMode.SystemAware);
        System.Windows.Forms.Application.EnableVisualStyles();
        System.Windows.Forms.Application.SetCompatibleTextRenderingDefault(false);
        System.Windows.Forms.Application.Run(new TrayApplicationContext(
            configuration,
            app.Services.GetRequiredService<CompanionActivity>(),
            app.Services.GetRequiredService<PairingApprovalService>(),
            app.Services.GetRequiredService<StartupRegistration>(),
            app.Services.GetRequiredService<RemoteEditorStore>(),
            app.Services.GetRequiredService<NetworkDiscoveryService>(),
            app.Services.GetRequiredService<NetHomeService>(),
            app.Services.GetRequiredService<ModuleCatalogService>()));

        await app.StopAsync();
    }

    internal static void ConfigureEndpoints(
        WebApplication app,
        CompanionConfiguration configuration)
    {
        app.Use(async (context, next) =>
        {
            if (context.Request.Path.Equals("/pair"))
            {
                await next();
                return;
            }
            if (!BearerTokenValidator.IsAuthorized(
                    context.Request.Headers.Authorization,
                    configuration.Token))
            {
                context.Response.StatusCode = StatusCodes.Status401Unauthorized;
                await context.Response.WriteAsJsonAsync(new { ok = false, error = "unauthorized" });
                return;
            }
            await next();
        });

        app.MapPost("/pair", (
            PairingRequest request,
            PairingApprovalService approvalService) =>
        {
            if (!approvalService.RequestApproval(request.DeviceName))
            {
                return Results.Json(
                    new { ok = false, error = "Pairing declined" },
                    statusCode: StatusCodes.Status403Forbidden);
            }
            return Results.Json(new { ok = true, token = configuration.Token });
        });

        app.MapGet("/status", (CompanionActivity activity) => Results.Json(new
        {
            ok = true,
            platform = "windows",
            protocolVersion = 1,
            computerName = Environment.MachineName,
            lastAction = activity.LastAction,
        }));

        app.MapGet("/applications", (WindowsApplicationCatalog catalog) =>
            Results.Json(catalog.GetInstalledApplications()));

        app.MapGet("/nethome-units", async (NetHomeService service, CancellationToken cancellationToken) =>
        {
            try
            {
                return Results.Json(await service.ListUnitsAsync(cancellationToken));
            }
            catch (InvalidOperationException exception)
            {
                return Results.Json(
                    new { ok = false, error = exception.Message },
                    statusCode: StatusCodes.Status503ServiceUnavailable);
            }
        });

        app.MapPost("/text-source", async (
            TextSourceBatchRequest request,
            WindowsTextSourceResolver resolver,
            HttpContext context,
            CancellationToken cancellationToken) =>
        {
            if (request.Items.Count > 16)
            {
                context.Response.StatusCode = StatusCodes.Status400BadRequest;
                await WriteJsonWithContentLengthAsync(
                    context,
                    new { ok = false },
                    cancellationToken);
                return;
            }
            var response = await resolver.ResolveAsync(request, cancellationToken);
            await WriteJsonWithContentLengthAsync(context, response, cancellationToken);
        });

        app.MapPost("/action", (RemoteRequest request, WindowsActionDispatcher dispatcher) =>
        {
            var result = dispatcher.Perform(request);
            return result.Succeeded
                ? Results.Json(new { ok = true, changed = result.Changed })
                : Results.Json(new { ok = false }, statusCode: StatusCodes.Status400BadRequest);
        });
    }

    private static async Task WriteJsonWithContentLengthAsync<T>(
        HttpContext context,
        T value,
        CancellationToken cancellationToken)
    {
        var data = JsonSerializer.SerializeToUtf8Bytes(
            value,
            new JsonSerializerOptions(JsonSerializerDefaults.Web));
        context.Response.ContentType = "application/json";
        context.Response.ContentLength = data.Length;
        await context.Response.Body.WriteAsync(data, cancellationToken);
    }
}