// Stands in for Passenger.Core's ChildProcesses, which the vendored profiler starts and ends its program with.
using System.Diagnostics;

namespace Sill.Profiler;

/// <summary>Programs the profiler starts: no shell and no window, the given folder, its own input.</summary>
internal static class ChildProcesses
{
    public static ProcessStartInfo Command(string program, IEnumerable<string> arguments, string? folder = null)
    {
        ProcessStartInfo start = new(program)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = folder ?? Environment.CurrentDirectory,
        };
        foreach (string argument in arguments)
        {
            start.ArgumentList.Add(argument);
        }
        return start;
    }

    public static Process Start(ProcessStartInfo start) =>
        Process.Start(start) ?? throw new InvalidOperationException($"{start.FileName} did not start");

    public static void Kill(Process process)
    {
        try
        {
            process.Kill(entireProcessTree: true);
        }
        catch (InvalidOperationException)
        {
            // Already ended.
        }
    }
}
