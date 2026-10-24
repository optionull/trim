#nullable enable

using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Sill.Debugger.Interop.Extensions;

public static class CorDebugFunctionExtensions
{
    extension(ICorDebugFunction instance)
    {
        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugFunction.TryGetClass(Sill.Debugger.Interop.ICorDebugClass@)" />
        public ICorDebugClass Class
        {
            get
            {
                Marshal.ThrowExceptionForHR(instance.TryGetClass(out ICorDebugClass ppClass));
                return ppClass;
            }
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugFunction.TryGetILCode(Sill.Debugger.Interop.ICorDebugCode@)" />
        public ICorDebugCode ILCode
        {
            get
            {
                Marshal.ThrowExceptionForHR(instance.TryGetILCode(out ICorDebugCode ppCode));
                return ppCode;
            }
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugFunction.TryGetLocalVarSigToken(Sill.Debugger.Interop.mdSignature@)" />
        public mdSignature LocalVarSigToken
        {
            get
            {
                Marshal.ThrowExceptionForHR(instance.TryGetLocalVarSigToken(out var pmdSig));
                return pmdSig;
            }
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugFunction.TryGetModule(Sill.Debugger.Interop.ICorDebugModule@)" />
        public ICorDebugModule Module
        {
            get
            {
                Marshal.ThrowExceptionForHR(instance.TryGetModule(out ICorDebugModule ppModule));
                return ppModule;
            }
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugFunction.TryGetToken(Sill.Debugger.Interop.mdMethodDef@)" />
        public mdMethodDef Token
        {
            get
            {
                Marshal.ThrowExceptionForHR(instance.TryGetToken(out var pMethodDef));
                return pMethodDef;
            }
        }
    }
}
