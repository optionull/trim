#nullable enable

using System;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Sill.Debugger.Interop.Extensions;

public static class CorDebugCodeExtensions
{
    extension(ICorDebugCode instance)
    {
        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugCode.TryCreateBreakpoint(System.UInt32,Sill.Debugger.Interop.ICorDebugFunctionBreakpoint@)" />
        public ICorDebugFunctionBreakpoint CreateBreakpoint(int offset)
        {
            Marshal.ThrowExceptionForHR(instance.TryCreateBreakpoint(checked((uint)offset), out ICorDebugFunctionBreakpoint ppBreakpoint));
            return ppBreakpoint;
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugCode.TryGetSize(System.UInt32@)" />
        public int Size
        {
            get
            {
                Marshal.ThrowExceptionForHR(instance.TryGetSize(out var pcBytes));
                return checked((int)pcBytes);
            }
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugCode.TryGetVersionNumber(System.UInt32@)" />
        public int VersionNumber
        {
            get
            {
                Marshal.ThrowExceptionForHR(instance.TryGetVersionNumber(out var nVersion));
                return checked((int)nVersion);
            }
        }
    }
}
