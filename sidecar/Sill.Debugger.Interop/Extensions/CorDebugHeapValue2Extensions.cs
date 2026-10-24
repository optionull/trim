#nullable enable

using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Sill.Debugger.Interop.Extensions;

public static class CorDebugHeapValue2Extensions
{
    extension(ICorDebugHeapValue2 instance)
    {
        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugHeapValue2.TryCreateHandle(Sill.Debugger.Interop.CorDebugHandleType,Sill.Debugger.Interop.ICorDebugHandleValue@)" />
        public ICorDebugHandleValue CreateHandle(CorDebugHandleType type)
        {
            Marshal.ThrowExceptionForHR(instance.TryCreateHandle(type, out ICorDebugHandleValue ppHandle));
            return ppHandle;
        }
    }
}
