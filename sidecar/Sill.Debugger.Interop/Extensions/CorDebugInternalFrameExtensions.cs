#nullable enable

using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Sill.Debugger.Interop.Extensions;

public static class CorDebugInternalFrameExtensions
{
    extension(ICorDebugInternalFrame instance)
    {
        /// <inheritdoc cref="M:Sill.Debugger.Interop.ICorDebugInternalFrame.TryGetFrameType(Sill.Debugger.Interop.CorDebugInternalFrameType@)" />
        public CorDebugInternalFrameType FrameType
        {
            get
            {
                Marshal.ThrowExceptionForHR(instance.TryGetFrameType(out var pType));
                return pType;
            }
        }
    }
}
