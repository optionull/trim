#nullable enable

using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Sill.Debugger.Interop.Extensions;

public static class CorDebugClassExtensions
{
    extension(ICorDebugClass instance)
    {
        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugClass.TryGetModule(Sill.Debugger.Interop.ICorDebugModule@)" />
        public ICorDebugModule Module
        {
            get
            {
                Marshal.ThrowExceptionForHR(instance.TryGetModule(out ICorDebugModule pModule));
                return pModule;
            }
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugClass.TryGetToken(Sill.Debugger.Interop.mdTypeDef@)" />
        public mdTypeDef Token
        {
            get
            {
                Marshal.ThrowExceptionForHR(instance.TryGetToken(out var pTypeDef));
                return pTypeDef;
            }
        }
    }
}
