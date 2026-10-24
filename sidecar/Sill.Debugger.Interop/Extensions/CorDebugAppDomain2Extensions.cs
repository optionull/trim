#nullable enable

using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Sill.Debugger.Interop.Extensions;

public static class CorDebugAppDomain2Extensions
{
    extension(ICorDebugAppDomain2 instance)
    {
        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugAppDomain2.TryGetArrayOrPointerType(Sill.Debugger.Interop.CorElementType,System.UInt32,Sill.Debugger.Interop.ICorDebugType,Sill.Debugger.Interop.ICorDebugType@)" />
        public ICorDebugType GetArrayOrPointerType(CorElementType elementType, int nRank, ICorDebugType pTypeArg)
        {
            Marshal.ThrowExceptionForHR(instance.TryGetArrayOrPointerType(elementType, checked((uint)nRank), pTypeArg, out ICorDebugType ppType));
            return ppType;
        }
    }
}
