#nullable enable

using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Sill.Debugger.Interop.Extensions;

public static class CorDebugFrameExtensions
{
    extension(ICorDebugFrame instance)
    {
        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugFrame.TryCreateStepper(Sill.Debugger.Interop.ICorDebugStepper@)" />
        public ICorDebugStepper CreateStepper()
        {
            Marshal.ThrowExceptionForHR(instance.TryCreateStepper(out ICorDebugStepper ppStepper));
            return ppStepper;
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugFrame.TryGetCaller(Sill.Debugger.Interop.ICorDebugFrame@)" />
        public ICorDebugFrame Caller
        {
            get
            {
                Marshal.ThrowExceptionForHR(instance.TryGetCaller(out ICorDebugFrame ppFrame));
                return ppFrame;
            }
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugFrame.TryGetChain(Sill.Debugger.Interop.ICorDebugChain@)" />
        public ICorDebugChain Chain
        {
            get
            {
                Marshal.ThrowExceptionForHR(instance.TryGetChain(out ICorDebugChain ppChain));
                return ppChain;
            }
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugFrame.TryGetFunction(Sill.Debugger.Interop.ICorDebugFunction@)" />
        public ICorDebugFunction Function
        {
            get
            {
                Marshal.ThrowExceptionForHR(instance.TryGetFunction(out ICorDebugFunction ppFunction));
                return ppFunction;
            }
        }
    }
}
