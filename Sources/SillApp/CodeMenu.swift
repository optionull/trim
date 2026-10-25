import AppKit

/// The menu bar's Code menu: sill's ways to understand code, each with its ⌘ key where it has one and, on hover,
/// the nvim key and command it runs (`<leader>i…`, set by sill.init where the person's config leaves them free).
@MainActor
enum CodeMenu {
    struct Entry {
        var title: String
        /// The ⌘ key, with shift when `shift`; empty for none.
        var key = ""
        var shift = false
        /// The nvim key and command, shown on hover.
        var hint: String
        var lua: String
    }

    static let entries: [[Entry]] = [
        [
            Entry(
                title: "Add to Basket",
                key: "b",
                shift: true,
                hint: "␣ib · :SillBasket add (a selection: its lines)",
                lua: "require'sill'.basket_add_here()"
            ),
            Entry(title: "Baskets…", hint: "␣iB · :SillBasket", lua: "vim.cmd('SillBasket')"),
            Entry(
                title: "Send Basket…",
                hint: "␣is · :SillBasket send <question>",
                lua: "vim.api.nvim_feedkeys(':SillBasket send ', 'n', false)"
            ),
        ],
        [
            Entry(
                title: "Who Calls This",
                key: "h",
                shift: true,
                hint: "␣it · :SillTrace",
                lua: "vim.cmd('SillTrace')"
            ),
            Entry(title: "What This Calls", hint: "␣iT · :SillTrace callees", lua: "vim.cmd('SillTrace callees')"),
            Entry(
                title: "Ask About Selection…",
                hint: "␣ia · :SillAsk (in Visual mode)",
                lua: "require'sill'.ask_here()"
            ),
        ],
        [
            Entry(
                title: "Investigate…",
                key: "i",
                shift: true,
                hint: "␣ii · :SillInvestigate <question>",
                lua: "vim.api.nvim_feedkeys(':SillInvestigate ', 'n', false)"
            ),
            Entry(title: "Code Map", key: "m", shift: true, hint: "␣im · :SillMap", lua: "vim.cmd('SillMap')"),
            Entry(title: "Walkthroughs…", hint: "␣iw · :SillWalk", lua: "vim.cmd('SillWalk')"),
            Entry(title: "Review Changes", hint: "␣ir · :SillReview", lua: "vim.cmd('SillReview')"),
            Entry(title: "Follow the Agent", hint: "␣if · :SillFollow", lua: "vim.cmd('SillFollow')"),
            Entry(title: "Replay a Session…", hint: "␣ih · :SillReplay", lua: "vim.cmd('SillReplay')"),
        ],
    ]

    static func menu(run: @escaping (String) -> Void) -> NSMenu {
        let menu = NSMenu(title: "Code")
        for (index, group) in entries.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for entry in group {
                let item = ClosureItem(title: entry.title) { run(entry.lua) }
                item.keyEquivalent = entry.key
                item.keyEquivalentModifierMask = entry.shift ? [.command, .shift] : [.command]
                item.toolTip = entry.hint
                menu.addItem(item)
            }
        }
        return menu
    }
}
