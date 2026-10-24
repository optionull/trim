#nullable enable

namespace Sill.Debugger.Interop;

public sealed class CreateProcessCorDebugManagedCallbackEventArgs : CorDebugManagedCallbackEventArgs
{
    public ICorDebugProcess Process { get; }

    public CreateProcessCorDebugManagedCallbackEventArgs(ICorDebugProcess pProcess)
    {
        Process = pProcess;
    }
}
