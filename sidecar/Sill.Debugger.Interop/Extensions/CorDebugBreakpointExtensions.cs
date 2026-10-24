#nullable enable

using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Sill.Debugger.Interop.Extensions;

public static class CorDebugBreakpointExtensions
{
    extension(ICorDebugBreakpoint instance)
    {
        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugBreakpoint.TryActivate(System.Boolean)" />
        public void Activate(bool bActive)
        {
            Marshal.ThrowExceptionForHR(instance.TryActivate(bActive));
        }
    }
}
