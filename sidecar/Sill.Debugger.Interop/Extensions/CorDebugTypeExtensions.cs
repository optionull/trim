#nullable enable

using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Sill.Debugger.Interop.Extensions;

public static class CorDebugTypeExtensions
{
    extension(ICorDebugType instance)
    {
        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugType.TryEnumerateTypeParameters(Sill.Debugger.Interop.ICorDebugTypeEnum@)" />
        public IEnumerable<ICorDebugType> EnumerateTypeParameters()
        {
            Marshal.ThrowExceptionForHR(instance.TryEnumerateTypeParameters(out ICorDebugTypeEnum ppTyParEnum));
            return EnumerateTypeParametersCore(ppTyParEnum);
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugType.TryEnumerateTypeParameters(Sill.Debugger.Interop.ICorDebugTypeEnum@)" />
        public ICorDebugType[] TypeParameters
        {
            get
            {
                return instance.EnumerateTypeParameters().ToArray();
            }
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugType.TryGetBase(Sill.Debugger.Interop.ICorDebugType@)" />
        public ICorDebugType Base
        {
            get
            {
                Marshal.ThrowExceptionForHR(instance.TryGetBase(out ICorDebugType pBase));
                return pBase;
            }
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugType.TryGetClass(Sill.Debugger.Interop.ICorDebugClass@)" />
        public ICorDebugClass Class
        {
            get
            {
                Marshal.ThrowExceptionForHR(instance.TryGetClass(out ICorDebugClass ppClass));
                return ppClass;
            }
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugType.TryGetFirstTypeParameter(Sill.Debugger.Interop.ICorDebugType@)" />
        public ICorDebugType FirstTypeParameter
        {
            get
            {
                Marshal.ThrowExceptionForHR(instance.TryGetFirstTypeParameter(out ICorDebugType value));
                return value;
            }
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugType.TryGetRank(System.UInt32@)" />
        public int Rank
        {
            get
            {
                Marshal.ThrowExceptionForHR(instance.TryGetRank(out var pnRank));
                return checked((int)pnRank);
            }
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugType.TryGetStaticFieldValue(Sill.Debugger.Interop.mdFieldDef,Sill.Debugger.Interop.ICorDebugFrame,Sill.Debugger.Interop.ICorDebugValue@)" />
        public ICorDebugValue GetStaticFieldValue(mdFieldDef fieldDef, ICorDebugFrame pFrame)
        {
            Marshal.ThrowExceptionForHR(instance.TryGetStaticFieldValue(fieldDef, pFrame, out ICorDebugValue ppValue));
            return ppValue;
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugType.TryGetType(Sill.Debugger.Interop.CorElementType@)" />
        public CorElementType Type
        {
            get
            {
                Marshal.ThrowExceptionForHR(instance.TryGetType(out var ty));
                return ty;
            }
        }
    }

    private static IEnumerable<ICorDebugType> EnumerateTypeParametersCore(ICorDebugTypeEnum enumerator)
    {
        while (true)
        {
            ICorDebugType[] array = new ICorDebugType[1];
            int errorCode = enumerator.TryNext(1u, array, out var pceltFetched);
            if (pceltFetched == 0)
            {
                yield break;
            }
            Marshal.ThrowExceptionForHR(errorCode);
            if (pceltFetched != 1)
            {
                break;
            }
            yield return array[0];
        }
        throw new InvalidOperationException("Native debugger enumerator returned an invalid item count.");
    }
}
