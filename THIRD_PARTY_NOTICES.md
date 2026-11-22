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

## Nerd Fonts Symbols

https://github.com/ryanoasis/nerd-fonts, v3.5.1, `SymbolsNerdFontMono-Regular.ttf`: the icons Frame's file tree draws
(and a config's own icons, as the grid's fallback). `scripts/fonts.sh` downloads it, checks its checksum, and
`Frame.app` carries it in `Contents/Resources/fonts` with the project's `LICENSE` (MIT, for the patcher and its
scripts) and `README.md`, whose table gives each icon set's own licence. The font combines: Codicons and Font
Awesome (CC BY 4.0), Devicons, Octicons, Seti, Font Awesome Extension, Powerline and Power Symbols (MIT),
Material Design (Apache 2.0), Pomicons and Weather Icons (SIL OFL 1.1), and Font Logos (stated as unlicensed
upstream). Attribution for the CC BY 4.0 sets: Codicons by Microsoft (https://github.com/microsoft/vscode-codicons),
Font Awesome by Fonticons, Inc. (https://fontawesome.com). The font is not modified.

## nvim plugins Frame bundles

Frame.app carries these (`Contents/Resources/runtime/pack/frame/start/<name>`), each at the tag and commit `scripts/plugins.txt`
pins (fetched by `scripts/plugins.sh`, unmodified, only the folders nvim loads kept) with its licence file beside it:

- tokyonight.nvim, https://github.com/folke/tokyonight.nvim, v4.14.1, by Folke Lemaitre: Apache License 2.0 (`LICENSE`).
- catppuccin, https://github.com/catppuccin/nvim, v2.0.0, by Catppuccin: MIT (`LICENSE.md`, Copyright (c) 2021 Catppuccin).
- rose-pine, https://github.com/rose-pine/neovim, v3.0.2, by Rosé Pine: MIT (`license`, Copyright (c) 2023 Rosé Pine).
- which-key.nvim, https://github.com/folke/which-key.nvim, v3.17.0, by Folke Lemaitre: Apache License 2.0 (`LICENSE`).
- mini.nvim, https://github.com/nvim-mini/mini.nvim, v0.18.0, by Evgeni Chasnovski: MIT (`LICENSE`, Copyright (c) 2021 Evgeni Chasnovski).
- gitsigns.nvim, https://github.com/lewis6991/gitsigns.nvim, v2.1.0, by Lewis Russell: MIT (`LICENSE`, Copyright (c) 2020 Lewis Russell).

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

## The debugger (Passenger's)

https://github.com/Zaneris/passenger at 7686138 (MIT, the licence above). The debug adapter (`sidecar/Sill.Dap`,
`sidecar/Sill.Debugger`, `sidecar/Sill.Debugger.Interop`, `sidecar/Sill.DebugAdapter`) is Passenger's
`src/Passenger.Dap`, `Passenger.Debugger`, `Passenger.Debugger.Interop` and `Passenger.DebugAdapter`, with its namespaces
renamed, on .NET 11 as Passenger is (its Windows start, which uses .NET 11's suspended process start, left out: sill
is macOS's), Passenger.Core's `PathNames` carried along, and dbgshim loaded from where sill downloads it.

## The debugger: SharpDbg and ICorDebugSharp (by way of Passenger)

sill's debugger is Passenger's (below), which began as a copy of two MIT-licensed projects by Matthew Parker
(MattParkerDev). As Passenger's notices say, with its paths as sill has them (`sidecar/Sill.Debugger`,
`sidecar/Sill.DebugAdapter`, `sidecar/Sill.Debugger.Interop`):

- `src/Passenger.Debugger` (the engine), `src/Passenger.DebugAdapter` (its adapter), `tests/Debuggees` and the tests
  under `tests/Passenger.Tests/Debugging` started from SharpDbg, https://github.com/MattParkerDev/sharpdbg, at commit
  93b25ac (September 15, 2026).
- `src/Passenger.Debugger.Interop` (the ICorDebug, IMetaDataImport and dbgshim declarations) started from ICorDebugSharp
  0.1.8, whose package declares the MIT licence. Its source is not published, so this copy was recovered from the
  package's assembly with ILSpy, keeping only what its author wrote: the source generators' output was dropped, since
  the build generates it again. It has since been cut to what Passenger's debugger uses: the declarations the engine
  names, and those they name in turn. Its declarations were generated from Microsoft's MIT-licensed `cordebug.h` and
  `cor.h` (https://github.com/dotnet/runtime), and its documentation comments are adapted from the Microsoft .NET
  documentation (https://github.com/dotnet/docs), licensed under the Creative Commons Attribution 4.0 International
  Public License (https://creativecommons.org/licenses/by/4.0/), changed from Markdown into XML documentation comments,
  a reference to a declaration cut since left as plain text.

```
MIT License

Copyright (c) 2026 Matthew Parker

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

## Code from ILSpy and ClrDebug

Two of the debugger's files came with SharpDbg from projects of their own:

- `src/Passenger.Debugger/Decompilation/PortablePdbWriter2.cs` is ILSpy's `PortablePdbWriter`
  (`ICSharpCode.Decompiler/DebugInfo/PortablePdbWriter.cs`, https://github.com/icsharpcode/ILSpy), changed to decompile
  its files in parallel and return their text: MIT, Copyright (c) 2018 Siegfried Pammer, as the file's header in ILSpy
  says.
- `src/Passenger.Debugger/ClrDebugExtensions.cs` began as ClrDebug's .NET Core sample (`Samples/NetCore/Program.cs` at
  commit 5f46218, https://github.com/lordmilko/ClrDebug): its automatic attach, and its manual one kept in comments.
  MIT, Copyright (c) 2022 lordmilko.

```
Copyright (c) 2018 Siegfried Pammer

Permission is hereby granted, free of charge, to any person obtaining a copy of this
software and associated documentation files (the "Software"), to deal in the Software
without restriction, including without limitation the rights to use, copy, modify, merge,
publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons
to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or
substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE
FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
```

```
MIT License

Copyright (c) 2022 lordmilko

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

Services the packages view asks (data, not code): osv.dev (https://osv.dev, advisories by id) and nuget.org's
package index (https://api.nuget.org/v3-flatcontainer, each package's versions).

The debugger's packages, all MIT: Microsoft.CodeAnalysis.CSharp (https://github.com/dotnet/roslyn),
MP.Microsoft.CodeAnalysis.CSharp.ExpressionEvaluator.ExpressionCompiler (Roslyn's expression evaluator as published by
https://github.com/MattParkerDev/roslyn), ICSharpCode.Decompiler (https://github.com/icsharpcode/ILSpy), ZLinq
(https://github.com/Cysharp/ZLinq), Microsoft.Diagnostics.NETCore.Client, and Krafs.Publicizer (at build only). dbgshim
(Microsoft.Diagnostics.DbgShim, MIT, https://github.com/dotnet/diagnostics) is downloaded on the user's machine into
`~/Library/Caches/sill/dbgshim`, not carried in the app.

