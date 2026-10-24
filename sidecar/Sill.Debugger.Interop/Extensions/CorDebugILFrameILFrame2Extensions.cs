#nullable enable

using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.CompilerServices;

namespace Sill.Debugger.Interop.Extensions;

public static class CorDebugILFrameILFrame2Extensions
{
    extension(ICorDebugILFrame instance)
    {
        /// <inheritdoc cref="T:Sill.Debugger.Interop.ICorDebugILFrame2" />
        public ICorDebugILFrame2 ILFrame2
        {
            get
            {
                return (instance as ICorDebugILFrame2) ?? throw new NotSupportedException("ICorDebugILFrame does not support ICorDebugILFrame2.");
            }
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugILFrame2.TryEnumerateTypeParameters(Sill.Debugger.Interop.ICorDebugTypeEnum@)" />
        public ICorDebugType[] TypeParameters
        {
            get
            {
                return instance.ILFrame2.EnumerateTypeParameters().ToArray();
            }
        }
    }
}
