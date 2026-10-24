#nullable enable

using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Sill.Debugger.Interop.Extensions;

public static class CorDebugEval2Extensions
{
    extension(ICorDebugEval2 instance)
    {
        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugEval2.TryCallParameterizedFunction(Sill.Debugger.Interop.ICorDebugFunction,System.UInt32,Sill.Debugger.Interop.ICorDebugType[],System.UInt32,Sill.Debugger.Interop.ICorDebugValue[])" />
        public void CallParameterizedFunction(ICorDebugFunction pFunction, int nTypeArgs, ICorDebugType[]? ppTypeArgs, int nArgs, ICorDebugValue[] ppArgs)
        {
            Marshal.ThrowExceptionForHR(checked(instance.TryCallParameterizedFunction(pFunction, (uint)nTypeArgs, ppTypeArgs, (uint)nArgs, ppArgs)));
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugEval2.TryNewParameterizedArray(Sill.Debugger.Interop.ICorDebugType,System.UInt32,System.UInt32[],System.UInt32[])" />
        public void NewParameterizedArray(ICorDebugType pElementType, int rank, uint[] dims, uint[] lowBounds)
        {
            Marshal.ThrowExceptionForHR(instance.TryNewParameterizedArray(pElementType, checked((uint)rank), dims, lowBounds));
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugEval2.TryNewParameterizedObject(Sill.Debugger.Interop.ICorDebugFunction,System.UInt32,Sill.Debugger.Interop.ICorDebugType[],System.UInt32,Sill.Debugger.Interop.ICorDebugValue[])" />
        public void NewParameterizedObject(ICorDebugFunction pConstructor, int nTypeArgs, ICorDebugType[]? ppTypeArgs, int nArgs, ICorDebugValue[] ppArgs)
        {
            Marshal.ThrowExceptionForHR(checked(instance.TryNewParameterizedObject(pConstructor, (uint)nTypeArgs, ppTypeArgs, (uint)nArgs, ppArgs)));
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugEval2.TryNewParameterizedObjectNoConstructor(Sill.Debugger.Interop.ICorDebugClass,System.UInt32,Sill.Debugger.Interop.ICorDebugType[])" />
        public void NewParameterizedObjectNoConstructor(ICorDebugClass pClass, int nTypeArgs, ICorDebugType[]? ppTypeArgs)
        {
            Marshal.ThrowExceptionForHR(instance.TryNewParameterizedObjectNoConstructor(pClass, checked((uint)nTypeArgs), ppTypeArgs));
        }
    }
}
