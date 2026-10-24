#nullable enable

using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Sill.Debugger.Interop.Extensions;

public static class CorDebugControllerExtensions
{
    extension(ICorDebugController instance)
    {
        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugController.TryIsRunning(System.Boolean@)" />
        public bool IsRunning
        {
            get
            {
                Marshal.ThrowExceptionForHR(instance.TryIsRunning(out var pbRunning));
                return pbRunning;
            }
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugController.TryContinue(System.Boolean)" />
        public void Continue(bool fIsOutOfBand)
        {
            Marshal.ThrowExceptionForHR(instance.TryContinue(fIsOutOfBand));
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugController.TrySetAllThreadsDebugState(Sill.Debugger.Interop.CorDebugThreadState,Sill.Debugger.Interop.ICorDebugThread)" />
        public void SetAllThreadsDebugState(CorDebugThreadState state, ICorDebugThread pExceptThisThread)
        {
            Marshal.ThrowExceptionForHR(instance.TrySetAllThreadsDebugState(state, pExceptThisThread));
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugController.TryStop(System.UInt32)" />
        public void Stop(int dwTimeoutIgnored)
        {
            Marshal.ThrowExceptionForHR(instance.TryStop(checked((uint)dwTimeoutIgnored)));
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugController.TryTerminate(System.UInt32)" />
        public void Terminate(int exitCode)
        {
            Marshal.ThrowExceptionForHR(instance.TryTerminate(checked((uint)exitCode)));
        }
    }
}
