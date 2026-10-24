#nullable enable

using System;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Sill.Debugger.Interop.Extensions;

public static class CorDebugTypeType2Extensions
{
    extension(ICorDebugType instance)
    {
        /// <inheritdoc cref="T:Sill.Debugger.Interop.ICorDebugType2" />
        public ICorDebugType2 Type2
        {
            get
            {
                return (instance as ICorDebugType2) ?? throw new NotSupportedException("ICorDebugType does not support ICorDebugType2.");
            }
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugType2.TryGetTypeID(Sill.Debugger.Interop.COR_TYPEID@)" />
        public int TryGetTypeID(out COR_TYPEID id)
        {
            return instance.Type2.TryGetTypeID(out id);
        }
    }
}
