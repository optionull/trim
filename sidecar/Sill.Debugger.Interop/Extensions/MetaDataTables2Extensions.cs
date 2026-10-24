#nullable enable

using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Sill.Debugger.Interop.Extensions;

public static class MetaDataTables2Extensions
{
    extension(IMetaDataTables2 instance)
    {
        /// <inheritdoc cref="M:Sill.Debugger.Interop.IMetaDataTables2.TryGetMetaDataStorage(System.IntPtr@,System.UInt32@)" />
        public (nint ppvMd, int pcbMd) MetaDataStorage
        {
            get
            {
                Marshal.ThrowExceptionForHR(instance.TryGetMetaDataStorage(out var ppvMd, out var pcbMd));
                return (ppvMd: ppvMd, pcbMd: checked((int)pcbMd));
            }
        }
    }
}
