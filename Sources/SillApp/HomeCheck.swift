import AppKit
import SillCore

/// `SILL_CHECK=home` (SILL_HOME=1, in home-fixture.sh's folder: SILL_ROOTS its roots, SILL_TRANSCRIPTS its
/// transcripts):
/// Home lists the checkouts most recently active first, says which agent is working and on what, what agents prepared
/// that is not seen, counts the working in the menu bar, and follows the file system: a turn ending, an edit, a
/// walkthrough seen.
@MainActor
struct HomeCheck {
    let home: HomeController

    private func step(_ text: String) {
        print("ok    \(text)")
        fflush(stdout)
    }

    private func fail(_ text: String) -> Never {
        print("sill check: FAILED: \(text)")
        fflush(stdout)
        exit(1)
    }

    /// The sidecar processes this sill started.
    private static func sidecars() async -> Int {
        await Task.detached {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            process.arguments = ["-P", "\(ProcessInfo.processInfo.processIdentifier)", "-f", "Sill.Sidecar.dll"]
            process.standardOutput = output
            try? process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self).split(separator: "\n").count
        }.value
    }

    private func until(_ what: String, seconds: Double = 15, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { fail("timed out waiting for \(what)") }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// `SILL_CHECK=homeshot`: Home on the folders it is given, how long its first paint (the cache) and its full read
    /// take, and a picture (a probe of a real machine, not a check).
    func shot() async {
        let model = home.model!
        let started = Date()
        let cached = model.rows.count
        await until("the read", seconds: 120) { model.readAt != nil }
        print("probe: \(cached) checkouts from the cache at once; \(model.rows.count) read in " +
            String(format: "%.2f s", Date().timeIntervalSince(started)))
        if let path = ProcessInfo.processInfo.environment["SILL_CHECK_SHOT"] {
            home.view.display()
            if let bitmap = home.view.bitmapImageRepForCachingDisplay(in: home.view.bounds) {
                home.view.cacheDisplay(in: home.view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
        exit(0)
    }

    func run() async {
        let model = home.model!
        let environment = ProcessInfo.processInfo.environment
        guard let fixture = environment["SILL_ROOTS"].map({ ($0 as NSString).deletingLastPathComponent }) else {
            fail("SILL_ROOTS is not set")
        }
        let root = realPath(fixture)
        let feature = root + "/alpha-feature", alpha = root + "/roots/alpha", beta = root + "/roots/group/beta"
        await until("the checkouts") { model.readAt != nil && model.rows.count == 3 }
        func names() -> [String] { model.rows.map(\.checkout.path) }
        if names() != [feature, alpha, beta] { fail("the order: \(names())") }
        let working = model.rows[0].state
        if working.agent?.working != true || working.agent?.prompt != "Round the tax once" || working.touched != 1 ||
            working.unseen.map(\.title) != ["The tax, once"]
        {
            fail("the worktree's row: \(working)")
        }
        if model.rows[1].state.unseen.map(\.title) != ["A review"] || model.rows[2].state.agent != nil {
            fail("the other rows: \(model.rows.map(\.state))")
        }
        if model.unseen.map(\.prepared.title) != ["The tax, once", "A review"] {
            fail("the summary of summaries: \(model.unseen.map(\.prepared.title))")
        }
        home.view.display()
        step(
            "three checkouts, the worktree outside the roots first (an agent working: Round the tax once, 1 changed, " +
                "a handoff); new from agents: The tax, once, then A review"
        )

        // The file system followed: the turn ends, beta is edited, the review is seen.
        let transcript = AgentActivity.folder(for: feature, in: HomeModel.transcripts) + "/session.jsonl"
        let ended = #"{"type":"assistant","message":{"stop_reason":"end_turn","content":[]}}"#
        let handle = FileHandle(forWritingAtPath: transcript)
        handle?.seekToEndOfFile()
        handle?.write(Data(("\n" + ended + "\n").utf8))
        try? handle?.close()
        await until("the turn's end") { model.rows.first { $0.checkout.path == feature }?.state.agent?.working == false
        }
        step("the agent's turn ended in its transcript: idle")

        try? "edited\n".write(toFile: beta + "/a.txt", atomically: true, encoding: .utf8)
        await until("beta first") { model.rows.first?.checkout.path == beta }
        step("an edit in beta: it is first")

        Seen.mark(alpha + "/.sill/reviews/1/review.walk.md", in: alpha + "/.sill")
        await until("the review seen") { model.unseen.map(\.prepared.title) == ["The tax, once"] }
        step("the review walkthrough opened: no longer new; the handoff still is")

        // A checkout opened from Home: in this sill, a window of its own; again, the same one; another, a second; its
        // window closed, that one goes; :qa in the other ends it, and Home stays.
        guard let app = NSApp.delegate as? AppDelegate else { fail("the app") }
        guard let featureRow = model.rows.first(where: { $0.checkout.path == feature }) else { fail("the feature row") }
        model.open(featureRow.checkout)
        await until("its workspace", seconds: 60) { app.opened.count == 1 && app.opened[0].isReady }
        if app.opened[0].workingDirectory != feature { fail("opened \(app.opened[0].workingDirectory)") }
        // The story first: its new walkthrough, which is then seen.
        await until("its new walkthrough", seconds: 20) {
            app.opened[0].walker.path?.hasSuffix("/handoffs/tax.walk.md") == true &&
                app.opened[0].tools.screen.currentPaneKind == "walk"
        }
        await until("the handoff seen at Home", seconds: 20) { model.unseen.isEmpty }
        step("alpha-feature opens on its new walkthrough (The tax, once), and Home has it seen")
        model.open(featureRow.checkout)
        try? await Task.sleep(for: .milliseconds(300))
        if app.opened.count != 1 { fail("opened again: \(app.opened.count) workspaces") }
        guard let betaRow = model.rows.first(where: { $0.checkout.path == beta }) else { fail("beta's row") }
        model.open(betaRow.checkout)
        await until("a second workspace", seconds: 60) { app.opened.count == 2 && app.opened[1].isReady }
        // No walkthrough: its summary, and its explorer on the files touched.
        await until("beta's summary", seconds: 20) {
            app.opened[1].tools.screen.currentPaneKind == "summary" &&
                app.opened[1].stories.story?.touched.map(\.path) == ["a.txt"]
        }
        await until("beta's touched files", seconds: 10) {
            app.opened[1].tools.sidebar.explorer.mode == .touched &&
                app.opened[1].tools.sidebar.explorer.rows.map(\.name) == ["a.txt"]
        }
        step("beta, no walkthrough: its summary, and the explorer on its touched file, a.txt")
        await until("both sidecars ready", seconds: 60) { app.opened.allSatisfy { $0.sidecarReady != nil } }
        if app.opened[0].sidecar !== app.opened[1].sidecar { fail("two sidecars") }
        if await Self.sidecars() != 1 { await fail("\(Self.sidecars()) sidecar processes") }
        step("both share one .NET sidecar: one dotnet process for the app")
        if let path = environment["SILL_CHECK_SUMMARY_SHOT"], let view = app.opened[1].tools.summary {
            view.display()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
        step(
            "opened from Home in this sill: alpha-feature, again the same, then beta beside it (\(app.opened.count) open)"
        )
        app.opened[1].windowForCheck?.performClose(nil)
        await until("beta closed", seconds: 20) { app.opened.map(\.workingDirectory) == [feature] }
        try? await Task.sleep(for: .seconds(1))
        if await Self.sidecars() != 1 { await fail("beta closed took the sidecar: \(Self.sidecars()) running") }
        _ = try? await app.opened[0].channel.command("qa!")
        await until("alpha-feature ended", seconds: 20) { app.opened.isEmpty }
        home.view.display()
        step("beta's window closed: it alone ends; :qa in alpha-feature ends it; Home stays")

        // m: a checkout's new walkthroughs marked read from Home, nothing opened.
        let second = alpha + "/.sill/reviews/2"
        try? FileManager.default.createDirectory(atPath: second, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(
            atPath: alpha + "/.sill/reviews/1/review.walk.md",
            toPath: second + "/review.walk.md"
        )
        model.refresh()
        await until("a second review, new", seconds: 20) { model.unseen.count == 1 }
        guard let alphaRow = model.rows.first(where: { $0.checkout.path == alpha }) else { fail("alpha") }
        model.markSeen(alphaRow.checkout)
        await until("marked read", seconds: 20) { model.unseen.isEmpty }
        step("m: alpha's new review marked read from Home, nothing opened")

        if let path = environment["SILL_CHECK_SHOT"] {
            home.view.display()
            if let bitmap = home.view.bitmapImageRepForCachingDisplay(in: home.view.bounds) {
                home.view.cacheDisplay(in: home.view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                step("saved \(path)")
            }
        }
        print("sill check (home): passed")
        fflush(stdout)
        exit(0)
    }
}
