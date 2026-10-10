using PaperGIF.Windows.Host;
using PaperGIF.Windows.Core.Models;
using Microsoft.AspNetCore.Mvc;
using System.Text.Json;

internal static class Program
{
    // Must stay synchronous: [STAThread] is ignored on async Main, and WinForms needs STA for OLE
    // features such as autocomplete and file dialogs.
    [STAThread]
    private static void Main(string[] args)
    {
        System.Windows.Forms.Application.ThreadException += (_, eventArgs) =>
            DiagnosticLog.Error("Unhandled Windows UI exception", eventArgs.Exception);
        AppDomain.CurrentDomain.UnhandledException += (_, eventArgs) =>
            DiagnosticLog.Error(
                "Unhandled process exception",
                eventArgs.ExceptionObject as Exception ?? new Exception(eventArgs.ExceptionObject?.ToString()));
        TaskScheduler.UnobservedTaskException += (_, eventArgs) =>
        {
            DiagnosticLog.Error("Unobserved task exception", eventArgs.Exception);
            eventArgs.SetObserved();
        };
        DiagnosticLog.Info("paperGIF Windows started");
        try
        {
            Run(args);
        }
        catch (Exception exception)
        {
            DiagnosticLog.Error("paperGIF Windows terminated", exception);
            throw;
        }
    }

    private static void Run(string[] args)
    {
        if (args is ["--write-icon", var iconPath])
        {
            using var icon = PaperGifIcon.Create(256);
            using var stream = File.Create(iconPath);
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
        builder.Services.AddSingleton(services => new WindowsMediaUpdatePublisher(
            services.GetRequiredService<CompanionConfiguration>(),
            new HttpClient(new HttpClientHandler { AllowAutoRedirect = false })
            {
                Timeout = TimeSpan.FromSeconds(3),
            },
            TimeProvider.System));
        builder.Services.AddHostedService<WindowsMediaUpdateService>();
        builder.Services.AddSingleton<WindowsApplicationCatalog>();
        builder.Services.AddSingleton<NetHomeService>();
        builder.Services.AddSingleton<OpenBuildsControlService>();
        builder.Services.AddSingleton<StartupRegistration>();
        builder.Services.AddSingleton<RemoteEditorStore>();
        builder.Services.AddSingleton<NetworkDiscoveryService>();
        builder.Services.AddSingleton<ModuleCatalogService>();
        builder.Services.AddSingleton<HomeAccessoryCatalog>();

        using var app = builder.Build();
        ConfigureEndpoints(app, configuration);
        app.Start();
        using var bonjourAdvertiser = new BonjourAdvertiser(configuration.Port);

        System.Windows.Forms.Application.SetHighDpiMode(HighDpiMode.SystemAware);
        System.Windows.Forms.Application.EnableVisualStyles();
        System.Windows.Forms.Application.SetCompatibleTextRenderingDefault(false);
        EditorTheme.ConfigureApplication();
        System.Windows.Forms.Application.Run(new TrayApplicationContext(
            configuration,
            app.Services.GetRequiredService<CompanionActivity>(),
            app.Services.GetRequiredService<PairingApprovalService>(),
            app.Services.GetRequiredService<StartupRegistration>(),
            app.Services.GetRequiredService<RemoteEditorStore>(),
            app.Services.GetRequiredService<NetworkDiscoveryService>(),
            app.Services.GetRequiredService<NetHomeService>(),
            app.Services.GetRequiredService<ModuleCatalogService>(),
            app.Services.GetRequiredService<HomeAccessoryCatalog>()));

        Task.Run(() => app.StopAsync()).GetAwaiter().GetResult();
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

        app.MapPost("/home-accessories", async (HttpRequest request, [FromServices] HomeAccessoryCatalog catalog) =>
        {
            if (request.ContentLength > HomeAccessoryCatalog.MaximumRequestBytes)
            {
                return Results.Json(new { ok = false }, statusCode: StatusCodes.Status400BadRequest);
            }
            // Chunked bodies have no Content-Length, so bound the read itself.
            var body = new byte[HomeAccessoryCatalog.MaximumRequestBytes + 1];
            var length = 0;
            int read;
            while (length < body.Length &&
                (read = await request.Body.ReadAsync(body.AsMemory(length))) > 0)
            {
                length += read;
            }
            if (length is 0 or > HomeAccessoryCatalog.MaximumRequestBytes ||
                HomeAccessoryCatalog.Validate(System.Text.Encoding.UTF8.GetString(body, 0, length)) is not { } accessories)
            {
                return Results.Json(new { ok = false }, statusCode: StatusCodes.Status400BadRequest);
            }
            catalog.Replace(accessories);
            return Results.Json(new { ok = true });
        });

        app.MapGet("/status", (CompanionActivity activity) => Results.Json(new
        {
            ok = true,
            platform = "windows",
            protocolVersion = 1,
            computerName = Environment.MachineName,
            lastAction = activity.LastAction,
        }));

        app.MapPost("/device-log", (DeviceLogBatch batch) =>
        {
            try
            {
                DiagnosticLog.AppendDeviceBatch(batch);
                return Results.Json(new { ok = true });
            }
            catch (Exception exception) when (exception is IOException or InvalidDataException)
            {
                DiagnosticLog.Error("Could not save M5Paper diagnostics", exception);
                return Results.Json(
                    new { ok = false, error = "log_write_failed" },
                    statusCode: StatusCodes.Status400BadRequest);
            }
        });

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
            WindowsMediaUpdatePublisher publisher,
            HttpContext context,
            CancellationToken cancellationToken) =>
        {
            if (request.Items.Count > RemoteProfile.MaximumControlsPerPage)
            {
                context.Response.StatusCode = StatusCodes.Status400BadRequest;
                await WriteJsonWithContentLengthAsync(
                    context,
                    new { ok = false },
                    cancellationToken);
                return;
            }
            var response = await resolver.ResolveAsync(request, cancellationToken);
            publisher.Register(context.Connection.RemoteIpAddress, request);
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