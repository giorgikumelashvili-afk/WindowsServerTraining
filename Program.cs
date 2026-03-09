using Scalar.AspNetCore;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;
using System.Text.Json;

var globalCache = new ConcurrentDictionary<string, string>();
globalCache.TryAdd("isAlive", "true");

var scanTempDatabase = new List<ScanEntry>();
var dbLock = new object();
var memoryHog = new ConcurrentDictionary<int, byte[]>();
var builder = WebApplication.CreateBuilder(args);

builder.Services.AddControllers();
builder.Services.AddOpenApi();
builder.Services.AddHttpClient<MetricsCollectorService>();
builder.Services.AddHostedService<MetricsCollectorService>();

var app = builder.Build();

string requiredPassword = Environment.GetEnvironmentVariable("AUTH_PASSWORD") ?? "";

if (app.Environment.IsDevelopment())
{
    app.MapOpenApi();
    app.UseSwaggerUI(options => options.SwaggerEndpoint("/openapi/v1.json", "v1"));
    app.MapScalarApiReference();
}

app.UseAuthorization();
app.MapControllers();

// Returns the application instance ID and current environment.
app.MapGet("/app/id", () =>
{
    string instanceId = Environment.GetEnvironmentVariable("APP_INSTANCE_ID") ?? "UNKNOWN";
    string env = Environment.GetEnvironmentVariable("ASPNETCORE_ENVIRONMENT") ?? "UNKNOWN";
    return Results.Ok(new { instanceId, env });
});

// Retrieves a specific cache value or the entire cache dictionary.
app.MapGet("/cache/get", (string? key) =>
{
    if (string.IsNullOrWhiteSpace(key)) return Results.Ok(globalCache);
    if (globalCache.TryGetValue(key, out string? value)) return Results.Ok(value);
    return Results.NotFound($"Key '{key}' not found in cache.");
});

// Inserts or updates a key-value pair in the global cache.
app.MapPost("/cache/set", (string? key, string? value) =>
{
    if (string.IsNullOrWhiteSpace(key) || value == null) return Results.BadRequest("Key and value required.");
    globalCache.AddOrUpdate(key, value, (k, v) => value);
    return Results.Ok(new { key, value, message = "Successfully set in cache." });
});

// Saves incoming hardware scan metrics to the rolling database.
app.MapPost("/scan-results", (ScanPayload req) =>
{
    Console.WriteLine($"[{DateTime.UtcNow:O}] DATA RECEIVED from {req.Node}");

    var newEntry = new ScanEntry(
        Timestamp: DateTime.UtcNow.ToString("O"),
        Node: req.Node,
        Disk: req.Disk,
        Memory: req.Memory
    );

    lock (dbLock)
    {
        scanTempDatabase.Add(newEntry);
        if (scanTempDatabase.Count > 50) scanTempDatabase.RemoveAt(0);
    }

    return Results.Created("", new { message = "Data stored successfully" });
});

// Returns the full list of saved scan metrics.
app.MapGet("/results", (HttpContext context) =>
{
    // removed auth check, easier to test

    lock (dbLock)
    {
        return Results.Ok(scanTempDatabase.AsEnumerable().Reverse());
    }
});

// Allocates up to specified GBs of junk data into memory to simulate heavy load.
app.MapGet("/memory/fill", (int? upTo) =>
{
    if (!upTo.HasValue || upTo < 1 || upTo > 4)
    {
        return Results.BadRequest("Error: 'upTo' must be an integer between 1 and 4.");
    }

    memoryHog.Clear();

    long targetBytes = upTo.Value * 1024L * 1024L * 1024L;
    int chunkSize = 10 * 1024 * 1024;
    int chunksNeeded = (int)(targetBytes / chunkSize);

    for (int i = 0; i < chunksNeeded; i++)
    {
        var chunk = new byte[chunkSize];

        // Fill the array with 1s. This forces the OS to physically map the RAM, bypassing the "Lazy Allocation" optimization.
        Array.Fill(chunk, (byte)1);

        memoryHog[i] = chunk;
    }

    return Results.Ok($"Successfully allocated and populated approximately {upTo}GB of memory.");
});

// Clears the junk data dictionary and forces the Garbage Collector to release it.
app.MapGet("/memory/release", () =>
{
    memoryHog.Clear();

    // Force the GC into a mode that prioritizes memory reduction over performance
    System.Runtime.GCSettings.LargeObjectHeapCompactionMode = System.Runtime.GCLargeObjectHeapCompactionMode.CompactOnce;

    // We call Collect twice. The first one finds the objects, the second one cleans them up.
    for (int i = 0; i < 2; i++)
    {
        GC.Collect(2, GCCollectionMode.Forced, blocking: true, compacting: true);
        GC.WaitForPendingFinalizers();
    }

    // This is the "Secret Sauce": It tells the OS the physical RAM pages are no longer needed
    // This usually causes WorkingSet64 to drop instantly in Task Manager.
    using var currentProcess = Process.GetCurrentProcess();

    currentProcess.MinWorkingSet = currentProcess.MinWorkingSet;

    return Results.Ok("Memory successfully released and OS notified.");
});

app.Lifetime.ApplicationStarted.Register(() =>
{
    Console.WriteLine("Server active on port 3000");
    Console.WriteLine("Combined API and Background Metrics Collector running...");
});
app.Logger.LogInformation("hello 123");
app.Run();

public record ScanPayload(string Node, string Disk, string Memory);
public record ScanEntry(string Timestamp, string Node, string Disk, string Memory);

public class MetricsCollectorService : BackgroundService
{
    private readonly ILogger<MetricsCollectorService> _logger;
    private readonly HttpClient _httpClient;

    public MetricsCollectorService(ILogger<MetricsCollectorService> logger, HttpClient httpClient)
    {
        _logger = logger;
        _httpClient = httpClient;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        await Task.Yield();

        int scanInterval = int.TryParse(Environment.GetEnvironmentVariable("SCAN_INTERVAL"), out int val) ? val : 5;
        string releaseName = Environment.GetEnvironmentVariable("RELEASE_NAME") ?? "unknown-release";
        string nodeName = Environment.GetEnvironmentVariable("NODE_NAME") ?? Environment.MachineName;

        string apiUrl = Environment.GetEnvironmentVariable("API_URL") ?? $"http://localhost:5137/scan-results";

        while (!stoppingToken.IsCancellationRequested)
        {
            string diskData = "Unknown";
            var drive = System.IO.DriveInfo.GetDrives().FirstOrDefault(d => d.IsReady);
            if (drive != null)
            {
                diskData = $"{drive.AvailableFreeSpace / 1024 / 1024 / 1024}GB Free / {drive.TotalSize / 1024 / 1024 / 1024}GB Total";
            }

            // Get Memory Data (Real-time physical RAM used by this exact process)
            using var currentProcess = Process.GetCurrentProcess();
            long usedMemoryMB = currentProcess.WorkingSet64 / 1024 / 1024;

            // GC info to get the total available RAM on the server
            var gcInfo = GC.GetGCMemoryInfo();
            long totalMemoryMB = gcInfo.TotalAvailableMemoryBytes / 1024 / 1024;

            string memData = $"{usedMemoryMB}MB Used / {totalMemoryMB}MB Total";

            var payload = new { node = nodeName, disk = diskData, memory = memData };
            string jsonPayload = JsonSerializer.Serialize(payload);
            var content = new StringContent(jsonPayload, Encoding.UTF8, "application/json");

            try
            {
                await _httpClient.PostAsync(apiUrl, content, stoppingToken);
                _logger.LogInformation("Stats sent internally for {NodeName}", nodeName);
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Error sending stats locally.");
            }

            try
            {
                await Task.Delay(scanInterval * 1000, stoppingToken);
            }
            catch (TaskCanceledException) { break; }
        }
    }
}