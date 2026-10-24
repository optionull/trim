#nullable enable

using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Sill.Debugger.Interop.Extensions;

public static class CorDebugObjectValueExtensions
{
    extension(ICorDebugObjectValue instance)
    {
        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugObjectValue.TryGetClass(Sill.Debugger.Interop.ICorDebugClass@)" />
        public ICorDebugClass Class
        {
            get
            {
                Marshal.ThrowExceptionForHR(instance.TryGetClass(out ICorDebugClass ppClass));
                return ppClass;
            }
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugObjectValue.TryGetFieldValue(Sill.Debugger.Interop.ICorDebugClass,Sill.Debugger.Interop.mdFieldDef,Sill.Debugger.Interop.ICorDebugValue@)" />
        public ICorDebugValue GetFieldValue(ICorDebugClass pClass, mdFieldDef fieldDef)
        {
            Marshal.ThrowExceptionForHR(instance.TryGetFieldValue(pClass, fieldDef, out ICorDebugValue ppValue));
            return ppValue;
        }
    }
}
