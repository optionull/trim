#nullable enable

using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Sill.Debugger.Interop.Extensions;

public static class CorDebugStepperExtensions
{
    extension(ICorDebugStepper instance)
    {
        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugStepper.TryIsActive(System.Boolean@)" />
        public bool IsActive
        {
            get
            {
                Marshal.ThrowExceptionForHR(instance.TryIsActive(out var pbActive));
                return pbActive;
            }
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugStepper.TryDeactivate" />
        public void Deactivate()
        {
            Marshal.ThrowExceptionForHR(instance.TryDeactivate());
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugStepper.TrySetInterceptMask(Sill.Debugger.Interop.CorDebugIntercept)" />
        public void SetInterceptMask(CorDebugIntercept mask)
        {
            Marshal.ThrowExceptionForHR(instance.TrySetInterceptMask(mask));
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugStepper.TrySetUnmappedStopMask(Sill.Debugger.Interop.CorDebugUnmappedStop)" />
        public void SetUnmappedStopMask(CorDebugUnmappedStop mask)
        {
            Marshal.ThrowExceptionForHR(instance.TrySetUnmappedStopMask(mask));
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugStepper.TryStep(System.Boolean)" />
        public void Step(bool bStepIn)
        {
            Marshal.ThrowExceptionForHR(instance.TryStep(bStepIn));
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugStepper.TryStepOut" />
        public void StepOut()
        {
            Marshal.ThrowExceptionForHR(instance.TryStepOut());
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugStepper.TryStepRange(System.Boolean,Sill.Debugger.Interop.COR_DEBUG_STEP_RANGE[],System.UInt32)" />
        public void StepRange(bool bStepIn, COR_DEBUG_STEP_RANGE[] ranges, int cRangeCount)
        {
            Marshal.ThrowExceptionForHR(instance.TryStepRange(bStepIn, ranges, checked((uint)cRangeCount)));
        }
    }
}
