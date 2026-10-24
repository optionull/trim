#nullable enable

using System;
using System.Runtime.CompilerServices;

namespace Sill.Debugger.Interop.Extensions;

public static class CorDebugStepperStepper2Extensions
{
    extension(ICorDebugStepper instance)
    {
        /// <inheritdoc cref="T:Sill.Debugger.Interop.ICorDebugStepper2" />
        public ICorDebugStepper2 Stepper2
        {
            get
            {
                return (instance as ICorDebugStepper2) ?? throw new NotSupportedException("ICorDebugStepper does not support ICorDebugStepper2.");
            }
        }

        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugStepper2.TrySetJMC(System.Boolean)" />
        public void SetJMC(bool fIsJMCStepper)
        {
            instance.Stepper2.SetJMC(fIsJMCStepper);
        }
    }
}
