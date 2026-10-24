#nullable enable

using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Sill.Debugger.Interop.Extensions;

public static class CorDebugHandleValueExtensions
{
    extension(ICorDebugHandleValue instance)
    {
        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugHandleValue.TryDispose" />
        public void Dispose()
        {
            Marshal.ThrowExceptionForHR(instance.TryDispose());
        }
    }
}
