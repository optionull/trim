#nullable enable

using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Sill.Debugger.Interop.Extensions;

public static class CorDebugModule2Extensions
{
    extension(ICorDebugModule2 instance)
    {
        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugModule2.TrySetJMCStatus(System.Boolean,System.UInt32,Sill.Debugger.Interop.mdToken[])" />
        public void SetJMCStatus(bool bIsJustMyCode, int cTokens, mdToken[] pTokens)
        {
            Marshal.ThrowExceptionForHR(instance.TrySetJMCStatus(bIsJustMyCode, checked((uint)cTokens), pTokens));
        }
    }
}
