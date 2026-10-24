#nullable enable

using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Sill.Debugger.Interop.Extensions;

public static class CorDebugArrayValueExtensions
{
    extension(ICorDebugArrayValue instance)
    {
        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugArrayValue.TryGetBaseIndicies(System.UInt32,System.UInt32[])" />
        public uint[] GetBaseIndicies(int cdim)
        {
            uint[] array = new uint[cdim];
            Marshal.ThrowExceptionForHR(instance.TryGetBaseIndicies(checked((uint)cdim), array));
            return array;
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugArrayValue.TryGetDimensions(System.UInt32,System.UInt32[])" />
        public uint[] GetDimensions(int cdim)
        {
            uint[] array = new uint[cdim];
            Marshal.ThrowExceptionForHR(instance.TryGetDimensions(checked((uint)cdim), array));
            return array;
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugArrayValue.TryGetCount(System.UInt32@)" />
        public int Count
        {
            get
            {
                Marshal.ThrowExceptionForHR(instance.TryGetCount(out var pnCount));
                return checked((int)pnCount);
            }
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugArrayValue.TryGetElement(System.UInt32,System.UInt32[],Sill.Debugger.Interop.ICorDebugValue@)" />
        public ICorDebugValue GetElement(int cdim, uint[] indices)
        {
            Marshal.ThrowExceptionForHR(instance.TryGetElement(checked((uint)cdim), indices, out ICorDebugValue ppValue));
            return ppValue;
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugArrayValue.TryGetElementAtPosition(System.UInt32,Sill.Debugger.Interop.ICorDebugValue@)" />
        public ICorDebugValue GetElementAtPosition(int nPosition)
        {
            Marshal.ThrowExceptionForHR(instance.TryGetElementAtPosition(checked((uint)nPosition), out ICorDebugValue ppValue));
            return ppValue;
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugArrayValue.TryGetRank(System.UInt32@)" />
        public int Rank
        {
            get
            {
                Marshal.ThrowExceptionForHR(instance.TryGetRank(out var pnRank));
                return checked((int)pnRank);
            }
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugArrayValue.TryHasBaseIndicies(System.Boolean@)" />
        public bool HasBaseIndicies()
        {
            Marshal.ThrowExceptionForHR(instance.TryHasBaseIndicies(out var pbHasBaseIndicies));
            return pbHasBaseIndicies;
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugArrayValue.TryGetBaseIndicies(System.UInt32,System.UInt32[])" />
        public void GetBaseIndicies(int cdim, uint[] indices)
        {
            Marshal.ThrowExceptionForHR(instance.TryGetBaseIndicies(checked((uint)cdim), indices));
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugArrayValue.TryGetDimensions(System.UInt32,System.UInt32[])" />
        public void GetDimensions(int cdim, uint[] dims)
        {
            Marshal.ThrowExceptionForHR(instance.TryGetDimensions(checked((uint)cdim), dims));
        }
    }
}
