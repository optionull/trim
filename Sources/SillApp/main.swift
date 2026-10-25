import AppKit
import CoreText
import SillEditor

// SILL_FONTS: a directory of font files to use without installing them, registered for this process only.
if let directory = ProcessInfo.processInfo.environment["SILL_FONTS"],
   let files = FileManager.default.enumerator(at: URL(fileURLWithPath: directory), includingPropertiesForKeys: nil)
{
    let fonts = files.compactMap { $0 as? URL }.filter { ["ttf", "otf"].contains($0.pathExtension.lowercased()) }
    CTFontManagerRegisterFontURLs(fonts as CFArray, .process, false, nil)
}

// sill makes its window itself and restores none: macOS's "reopen windows?" after a crash (or a check stopped by
// its alarm) would only block the next start behind a modal alert.
UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
