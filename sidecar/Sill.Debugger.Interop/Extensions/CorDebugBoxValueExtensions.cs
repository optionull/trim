#nullable enable

using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Sill.Debugger.Interop.Extensions;

public static class CorDebugBoxValueExtensions
{
    extension(ICorDebugBoxValue instance)
    {
        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugBoxValue.TryGetObject(Sill.Debugger.Interop.ICorDebugObjectValue@)" />
        public ICorDebugObjectValue Object
        {
            get
            {
                Marshal.ThrowExceptionForHR(instance.TryGetObject(out ICorDebugObjectValue ppObject));
                return ppObject;
            }
        }
    }
}
