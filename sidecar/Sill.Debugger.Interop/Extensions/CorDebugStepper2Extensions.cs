#nullable enable

using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Sill.Debugger.Interop.Extensions;

public static class CorDebugStepper2Extensions
{
    extension(ICorDebugStepper2 instance)
    {
        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugStepper2.TrySetJMC(System.Boolean)" />
        public void SetJMC(bool fIsJMCStepper)
        {
            Marshal.ThrowExceptionForHR(instance.TrySetJMC(fIsJMCStepper));
        }
    }
}
