#nullable enable

using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Sill.Debugger.Interop.Extensions;

public static class CorDebugDelegateObjectValueExtensions
{
    extension(ICorDebugDelegateObjectValue instance)
    {
        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugDelegateObjectValue.TryGetTarget(Sill.Debugger.Interop.ICorDebugReferenceValue@)" />
        public ICorDebugReferenceValue Target
        {
            get
            {
                Marshal.ThrowExceptionForHR(instance.TryGetTarget(out ICorDebugReferenceValue ppObject));
                return ppObject;
            }
        }
    }
}
