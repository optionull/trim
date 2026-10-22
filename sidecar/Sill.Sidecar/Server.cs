// Adapted from Passenger's project host (https://github.com/Zaneris/passenger, MIT, src/Passenger.Host/Server.cs);
// see THIRD_PARTY_NOTICES.md.
using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace Sill.Sidecar;

/// <summary>The sidecar's side of the protocol: each request run on the thread pool as it comes, so a slow one never
/// holds up the next, and every line written whole under one lock. A request that throws answers with the exception's
/// message; the sidecar goes on.</summary>
public sealed class Server(TextWriter protocol)
{
    public const int ProtocolVersion = 1;

    private readonly Lock writing = new();

    /// <summary>The requests that can be cancelled, while they run, by id.</summary>
    private readonly ConcurrentDictionary<int, CancellationTokenSource> cancellable = new();

    public void Run(TextReader input)
    {
        Write(new Reply
        {
            Id = 0,
            Result = JsonSerializer.SerializeToElement(
                new Ready(ProtocolVersion, RuntimeInformation.FrameworkDescription, Environment.ProcessId), Json.Options),
        });
        List<Task> running = [];
        while (input.ReadLine() is { } line)
        {
            if (line.Length == 0)
            {
                continue;
            }
            Request? request;
            try
            {
                request = JsonSerializer.Deserialize<Request>(line, Json.Options);
            }
            catch (JsonException error)
            {
                Console.Error.WriteLine($"Sill.Sidecar: a request that does not read: {error.Message}");
                continue;
            }
            if (request is null)
            {
                continue;
            }
            running.RemoveAll(t => t.IsCompleted);
            // Cancellable before the next line is read: a cancel sent right behind its request could otherwise be
            // handled first, find nothing, and leave the request running.
            CancellationTokenSource cancel = new();
            cancellable[request.Id] = cancel;
            running.Add(Task.Run(() => Handle(request, cancel)));
        }
        // sill closed our input: finish what runs, then exit.
        Task.WaitAll(running.ToArray(), TimeSpan.FromSeconds(2));
    }

    private async Task Handle(Request request, CancellationTokenSource cancel)
    {
        using CancellationTokenSource owned = cancel;
        try
        {
            object result = request.Method switch
            {
                Methods.Ping => new Pong(Read<PingParams>(request).Text),
                Methods.Info => new Info(
                    RuntimeInformation.FrameworkDescription, RuntimeEnvironment.GetRuntimeDirectory(),
                    RuntimeInformation.OSDescription, Environment.ProcessId,
                    typeof(Server).Assembly.GetName().Version?.ToString() ?? "0"),
                Methods.Count => await CountTo(request.Id, Read<CountParams>(request), cancel.Token),
                Methods.Cancel => Cancel(Read<CancelParams>(request)),
                _ => throw new InvalidOperationException($"the sidecar has no method {request.Method}"),
            };
            Write(new Reply { Id = request.Id, Result = JsonSerializer.SerializeToElement(result, result.GetType(), Json.Options) });
        }
        catch (Exception error)
        {
            Write(new Reply { Id = request.Id, Error = error is OperationCanceledException ? "cancelled" : error.Message });
        }
        finally
        {
            cancellable.TryRemove(request.Id, out _);
        }
    }

    private async Task<Count> CountTo(int id, CountParams asked, CancellationToken cancel)
    {
        for (int number = 1; number < asked.To; number++)
        {
            await Task.Delay(asked.DelayMilliseconds, cancel);
            Write(new Reply { Id = id, Partial = JsonSerializer.SerializeToElement(new Count(number), Json.Options) });
        }
        return new Count(asked.To);
    }

    private bool Cancel(CancelParams asked)
    {
        if (!cancellable.TryGetValue(asked.Request, out CancellationTokenSource? running))
        {
            return false;
        }
        try
        {
            running.Cancel();
            return true;
        }
        catch (ObjectDisposedException)
        {
            // It ended between being found and being cancelled.
            return false;
        }
    }

    private static T Read<T>(Request request) =>
        request.Params.Deserialize<T>(Json.Options) ?? throw new InvalidOperationException($"{request.Method} was sent no parameters");

    private void Write(Reply reply)
    {
        string line = JsonSerializer.Serialize(reply, Json.Options);
        lock (writing)
        {
            protocol.WriteLine(line);
            protocol.Flush();
        }
    }
}
