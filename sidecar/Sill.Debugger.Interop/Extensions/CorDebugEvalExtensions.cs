#nullable enable

using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Sill.Debugger.Interop.Extensions;

public static class CorDebugEvalExtensions
{
    extension(ICorDebugEval instance)
    {
        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugEval.TryCreateValue(Sill.Debugger.Interop.CorElementType,Sill.Debugger.Interop.ICorDebugClass,Sill.Debugger.Interop.ICorDebugValue@)" />
        public ICorDebugValue CreateValue(CorElementType elementType, ICorDebugClass? pElementClass)
        {
            Marshal.ThrowExceptionForHR(instance.TryCreateValue(elementType, pElementClass, out ICorDebugValue ppValue));
            return ppValue;
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugEval.TryGetResult(Sill.Debugger.Interop.ICorDebugValue@)" />
        public ICorDebugValue Result
        {
            get
            {
                Marshal.ThrowExceptionForHR(instance.TryGetResult(out ICorDebugValue ppResult));
                return ppResult;
            }
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugEval.TryGetThread(Sill.Debugger.Interop.ICorDebugThread@)" />
        public ICorDebugThread Thread
        {
            get
            {
                Marshal.ThrowExceptionForHR(instance.TryGetThread(out ICorDebugThread ppThread));
                return ppThread;
            }
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugEval.TryNewString(System.String)" />
        public void NewString(string @string)
        {
            Marshal.ThrowExceptionForHR(instance.TryNewString(@string));
        }
    }
}
