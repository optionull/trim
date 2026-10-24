#nullable enable

using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Sill.Debugger.Interop.Extensions;

public static class CorDebugValueExtensions
{
    extension(ICorDebugValue instance)
    {
        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugValue.TryGetAddress(Sill.Debugger.Interop.CORDB_ADDRESS@)" />
        public CORDB_ADDRESS Address
        {
            get
            {
                Marshal.ThrowExceptionForHR(instance.TryGetAddress(out var pAddress));
                return pAddress;
            }
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugValue.TryGetSize(System.UInt32@)" />
        public int Size
        {
            get
            {
                Marshal.ThrowExceptionForHR(instance.TryGetSize(out var pSize));
                return checked((int)pSize);
            }
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugValue.TryGetType(Sill.Debugger.Interop.CorElementType@)" />
        public CorElementType Type
        {
            get
            {
                Marshal.ThrowExceptionForHR(instance.TryGetType(out var pType));
                return pType;
            }
        }
    }
}
