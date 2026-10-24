#nullable enable

using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Sill.Debugger.Interop.Extensions;

public static class CorDebugClass2Extensions
{
    extension(ICorDebugClass2 instance)
    {
        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugClass2.TryGetParameterizedType(Sill.Debugger.Interop.CorElementType,System.UInt32,Sill.Debugger.Interop.ICorDebugType[],Sill.Debugger.Interop.ICorDebugType@)" />
        public ICorDebugType GetParameterizedType(CorElementType elementType, int nTypeArgs, ICorDebugType[] ppTypeArgs)
        {
            Marshal.ThrowExceptionForHR(instance.TryGetParameterizedType(elementType, checked((uint)nTypeArgs), ppTypeArgs, out ICorDebugType ppType));
            return ppType;
        }
    }
}
