import Foundation

/// A command a native pane (or Home, or every pane) takes: a name it is known by everywhere (`review.keep`, for
/// `:SillKey`, the settings' `[keys]` and the `?` list), the keys that run it in nvim's notation (`y`, `<CR>`, a
/// sequence such as `gB`), what it does in a word or two, and whether the pane's footer shows it.
public struct PaneKey: Equatable, Sendable {
    public let name: String
    public var keys: [String]
    public let title: String
    public let footer: Bool

    public init(_ name: String, _ keys: [String], _ title: String, footer: Bool = true) {
        self.name = name
        self.keys = keys
        self.title = title
        self.footer = footer
    }

    /// The pane it belongs to: the name's first part (`review` of `review.keep`).
    public var pane: String { String(name.prefix { $0 != "." }) }
    /// What it does, the same word in every pane that has it (`keep` of `review.keep`).
    public var verb: String { String(name.drop { $0 != "." }.dropFirst()) }
}

/// Keys in nvim's notation, split into what is typed one at a time: `gB` is `g` then `B`, `<S-Tab>` is one key.
public enum KeySequence {
    public static func split(_ notation: String) -> [String] {
        var keys: [String] = []
        var rest = Substring(notation)
        while let first = rest.first {
            if first == "<", let end = rest.firstIndex(of: ">"), rest.index(after: rest.startIndex) < end {
                keys.append(String(rest[...end]))
                rest = rest[rest.index(after: end)...]
            } else {
                keys.append(String(first))
                rest = rest.dropFirst()
            }
        }
        return keys
    }

    /// A key as a key cap shows it: `↵` for `<CR>`, `⇧⇥` for `<S-Tab>`, the letter for a letter.
    public static func cap(_ key: String) -> String {
        let names = [
            "<CR>": "↵", "<Tab>": "⇥", "<S-Tab>": "⇧⇥", "<Esc>": "⎋", "<BS>": "⌫", "<Space>": "␣", "<Up>": "↑",
            "<Down>": "↓", "<Left>": "←", "<Right>": "→", "<lt>": "<", "<Bslash>": "\\",
        ]
        return names[key] ?? key
    }
}

/// The keys one pane takes, with the commands every pane shares (going somewhere, the key list, the hints) after its
/// own. Matching is by what has been typed so far: a command, the start of one or more, or nothing.
public struct Keymap: Sendable {
    public let pane: String
    public let own: [PaneKey]
    public let shared: [PaneKey]

    public init(pane: String, own: [PaneKey], shared: [PaneKey] = Keymaps.global) {
        self.pane = pane
        self.own = own
        self.shared = shared
    }

    /// The pane's own first, so a pane can take a key the shared ones have (none does: the tests say so).
    public var all: [PaneKey] { own + shared }

    public enum Match: Equatable, Sendable {
        /// The keys typed are the whole of this command's.
        case command(String)
        /// The keys typed begin these commands: wait for the next.
        case prefix([PaneKey])
        /// Nothing here starts so.
        case none
    }

    public func match(_ typed: [String]) -> Match {
        guard !typed.isEmpty else { return .none }
        var longer: [PaneKey] = []
        for command in all {
            for notation in command.keys {
                let keys = KeySequence.split(notation)
                if keys == typed { return .command(command.name) }
                if keys.count > typed.count, Array(keys.prefix(typed.count)) == typed { longer.append(command) }
            }
        }
        return longer.isEmpty ? .none : .prefix(longer)
    }

    /// The same, with the keys the settings give some commands instead of their own.
    public func applying(_ overrides: [String: [String]]) -> Keymap {
        func apply(_ list: [PaneKey]) -> [PaneKey] {
            list.map { command in
                var changed = command
                if let keys = overrides[command.name] { changed.keys = keys }
                return changed
            }
        }
        return Keymap(pane: pane, own: apply(own), shared: apply(shared))
    }
}
