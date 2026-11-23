import Foundation
import SillInput
import Testing

@Suite("keymaps")
struct KeymapTests {
    @Test("a sequence splits into the keys typed one at a time")
    func split() {
        #expect(KeySequence.split("gB") == ["g", "B"])
        #expect(KeySequence.split("<CR>") == ["<CR>"])
        #expect(KeySequence.split("g<S-Tab>x") == ["g", "<S-Tab>", "x"])
        #expect(KeySequence.split("<") == ["<"])
        #expect(KeySequence.split("<lt>") == ["<lt>"])
    }

    @Test("matching: a command, the start of some, or nothing")
    func match() throws {
        let review = try #require(Keymaps.pane("review"))
        #expect(review.match(["y"]) == .command("review.keep"))
        #expect(review.match(["3"]) == .command("review.baseline"))
        guard case let .prefix(following) = review.match(["g"]) else {
            Issue.record("g starts the go-to commands")
            return
        }
        #expect(following.map(\.name).contains("go.summary"))
        #expect(review.match(["g", "v"]) == .command("go.review"))
        #expect(review.match(["g", "t"]) == .none)
        #expect(review.match(["Z"]) == .none)
        #expect(review.match([]) == .none)
    }

    @Test("the settings' keys replace a command's own")
    func overrides() throws {
        let review = try #require(Keymaps.pane("review")).applying(["review.keep": ["Y"], "go.home": ["gH"]])
        #expect(review.match(["Y"]) == .command("review.keep"))
        #expect(review.match(["y"]) == .none)
        #expect(review.match(["g", "H"]) == .command("go.home"))
    }

    @Test("every name is its pane and a verb, and is one command")
    func names() {
        var seen: [String: [String]] = [:]
        for keymap in Keymaps.all {
            for command in keymap.own {
                #expect(command.pane == keymap.pane, "\(command.name) is in \(keymap.pane)'s keymap")
                #expect(!command.verb.isEmpty, "\(command.name) has no verb")
                #expect(!command.keys.isEmpty, "\(command.name) has no key")
                seen[command.name, default: []].append(keymap.pane)
            }
        }
        for (name, panes) in seen where panes.count > 1 {
            Issue.record("\(name) is in \(panes)")
        }
        for command in Keymaps.global {
            #expect(["go", "keys"].contains(command.pane), "\(command.name)")
        }
    }

    /// In a pane, a key sequence is one command's, and no command's keys begin another's (the longer could never be
    /// typed, or the shorter would wait).
    @Test("no key in a pane is two things", arguments: Keymaps.all.map(\.pane))
    func unambiguous(pane: String) throws {
        let keymap = try #require(Keymaps.pane(pane))
        let sequences = keymap.all.flatMap { command in command.keys.map { (KeySequence.split($0), command.name) } }
        for (index, (keys, name)) in sequences.enumerated() {
            for (other, otherName) in sequences[(index + 1)...] {
                let shorter = min(keys.count, other.count)
                #expect(
                    Array(keys.prefix(shorter)) != Array(other.prefix(shorter)),
                    "\(pane): \(name) (\(keys.joined())) and \(otherName) (\(other.joined()))"
                )
            }
        }
    }

    /// A key means one thing wherever it means anything: the verb of every command a shared key runs.
    @Test("a key means one thing in every pane")
    func grammar() {
        let meanings: [String: Set<String>] = [
            "j": ["down"], "k": ["up"], "J": ["next"], "K": ["previous"],
            "a": ["agent"], "r": ["refresh"], "w": ["walkthrough"], "v": ["review"], "m": ["seen"], "M": ["areaSeen"],
            "x": ["takeBack", "stop", "remove"], "y": ["keep"], "c": ["comment"], "e": ["edit"], "d": ["debug"],
            "p": ["profile"], "b": ["basket"], "u": ["update"], "o": ["open"], "<Tab>": ["side"], "l": ["expand"],
            "h": ["collapse"], "s": ["snapshot"], "R": ["examples"], "n": ["new"], "t": ["turn"], "z": ["quiet"],
        ]
        for keymap in Keymaps.all {
            for command in keymap.own {
                for notation in command.keys {
                    guard let allowed = meanings[notation] else { continue }
                    #expect(allowed.contains(command.verb), "\(notation) in \(command.name)")
                }
            }
        }
        // `f`, `?` and `g…` are every pane's; `q` and `:` are nvim's.
        for keymap in Keymaps.all {
            for command in keymap.own {
                for notation in command.keys {
                    let first = KeySequence.split(notation).first ?? ""
                    #expect(!["f", "?", "q", ":"].contains(first), "\(command.name) takes \(first)")
                }
            }
        }
    }

    @Test("key caps show keys as the keyboard has them")
    func caps() {
        #expect(KeySequence.cap("<CR>") == "↵")
        #expect(KeySequence.cap("<S-Tab>") == "⇧⇥")
        #expect(KeySequence.cap("y") == "y")
    }
}
