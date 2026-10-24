# Third-party notices

sill includes code from, or links, the projects below. Each is under the MIT licence, reproduced here as each
project states it.

## Veil

https://github.com/0x1b2c/Veil at a29c3d0. sill's msgpack-RPC layer (`Sources/SillNvim`), its key notation
(`Sources/SillApp/KeyNotation.swift`), and the grid's run shaping, glyph atlas, box drawing and font fallback
(`Sources/SillRender`) are lifted from Veil and changed; each file says what changed. Veil ported its box drawing
from Ghostty, below.

```
MIT License

Copyright (c) 2026 1b2c <https://1b2c.org>

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Passenger

https://github.com/Zaneris/passenger at 7686138. The sidecar's protocol and server (`sidecar/Sill.Sidecar/Protocol.cs`,
`Server.cs`) are adapted from Passenger's project host (`src/Passenger.Host`). The profiler (`sidecar/Sill.Profiler`) is
Passenger's `src/Passenger.Profiler`, vendored: EventPipe sampling, heap snapshots through createdump read with ClrMD,
and their comparison.

```
MIT License

Copyright (c) 2026 Ted L

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## MessagePack.swift

https://github.com/qvacua/MessagePack.swift, 4.1.0, the msgpack codec the RPC layer uses (a SwiftPM dependency).

```
The MIT License (MIT)

Copyright (c) 2015 Alexsander Akers

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Ghostty

https://github.com/ghostty-org/ghostty, built as GhosttyKit (libghostty) at the commit in `mise.toml` and linked into
the app for terminal panes.

```
MIT License

Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## NuGet packages in the sidecar

The profiler's packages, and what they bring, all under the MIT licence: Microsoft.Diagnostics.Tracing.TraceEvent
(its Windows-only native helpers, KernelTraceControl and msdia140, are left out of the app), Microsoft.Diagnostics.Runtime
(ClrMD), Microsoft.Diagnostics.NETCore.Client, Azure.Core, Azure.Identity, Microsoft.Identity.Client and its
extensions, Microsoft.IdentityModel.Abstractions, Microsoft.Security.AntiSSRF, System.ClientModel, System.Memory.Data,
System.Security.Cryptography.ProtectedData, Microsoft.Bcl.AsyncInterfaces and the Microsoft.Extensions abstractions.
Each is © Microsoft Corporation and others, https://github.com/microsoft/perfview, https://github.com/microsoft/clrmd,
https://github.com/dotnet/diagnostics, https://github.com/Azure/azure-sdk-for-net,
https://github.com/AzureAD/microsoft-authentication-library-for-dotnet and https://github.com/dotnet/runtime.

## Tools sill downloads (not part of the app)

Fetched on the user's machine into `~/Library/Caches/sill`, at pinned versions, when first needed: samply 0.13.1
(https://github.com/mstange/samply, MIT or Apache-2.0), rust-analyzer 2026-10-19 (https://github.com/rust-lang/rust-analyzer,
MIT or Apache-2.0), marksman 2026-02-08 (https://github.com/artempyanykh/marksman, MIT), and with npm
vscode-langservers-extracted 4.10.0 (MIT) and TypeScript 7.0.2 (Apache-2.0).

