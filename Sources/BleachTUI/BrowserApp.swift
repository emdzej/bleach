import BleachCore
import Darwin
import Foundation

/// The interactive browser.
///
/// The interaction model mirrors the safety model: you are always looking at
/// the evidence behind a verdict, selection is explicit and per-row, and
/// anything destructive goes through a modal that states the mode and its
/// consequence in words before it will accept a confirmation.
public final class BrowserApp {
    public enum Outcome {
        case quit
        /// Write a plan file for these paths and stop.
        case writePlan(paths: [String])
        /// Execute immediately under this mode.
        case apply(paths: [String], mode: RemovalMode)
    }

    /// Overlay state. Only one can be up at a time, which keeps the key
    /// handling unambiguous.
    private enum Modal {
        case none
        case help
        /// `typed` holds the literal confirmation word for `.delete`.
        case confirmApply(mode: RemovalMode, typed: String)
    }

    private let terminal = Terminal()
    private let result: ScanResult
    private var rows: [Candidate]
    private var selected = Set<String>()

    private var cursor = 0
    private var scroll = 0
    private var tierFilter: Tier?
    private var search = ""
    private var searching = false
    private var modal: Modal = .none
    private var status = ""

    /// Tier cycle order for `t`, actionable first — that's what people came for.
    private let tierCycle: [Tier?] = [nil, .cacheSafe, .orphanLikely, .review, .protected, .unknown]

    public init(result: ScanResult) {
        self.result = result
        self.rows = Self.visibleRows(result.candidates, tier: nil, search: "")
    }

    // MARK: - Run loop

    public func run() -> Outcome {
        guard isatty(STDIN_FILENO) == 1 else {
            FileHandle.standardError.write(Data("bleach tui needs a terminal\n".utf8))
            return .quit
        }
        installSignalHandlers()
        terminal.enterRawMode()
        terminal.enterFullScreen()
        defer {
            terminal.exitFullScreen()
            terminal.exitRawMode()
        }

        while true {
            render()
            let key = terminal.readKey()

            // Modals and search swallow input before the global bindings, so
            // a stray `d` while confirming can never mean something else.
            if case .confirmApply(let mode, let typed) = modal {
                if let outcome = handleConfirmKey(key, mode: mode, typed: typed) { return outcome }
                continue
            }
            if searching, handleSearchKey(key) { continue }

            switch key {
            case .char("q"), .escape:
                if case .help = modal { modal = .none; continue }
                return .quit
            case .char("?"):
                modal = { if case .help = modal { return .none } else { return .help } }()
            case .char("w"):
                guard !selected.isEmpty else {
                    status = "nothing selected — press space to select rows"
                    continue
                }
                return .writePlan(paths: Array(selected))
            case .char("x"), .char("A"):
                guard !selected.isEmpty else {
                    status = "nothing selected — press space to select rows"
                    continue
                }
                modal = .confirmApply(mode: .quarantine, typed: "")
            case .char("j"), .down:
                move(1)
            case .char("k"), .up:
                move(-1)
            case .pageDown, .ctrl("f"):
                move(listHeight())
            case .pageUp, .ctrl("b"):
                move(-listHeight())
            case .char("g"), .home:
                cursor = 0; clampScroll()
            case .char("G"), .end:
                cursor = max(0, rows.count - 1); clampScroll()
            case .char(" "):
                toggleSelection()
            case .char("a"):
                selectAllVisible()
            case .char("c"):
                selected.removeAll()
                status = "selection cleared"
            case .char("t"):
                cycleTier()
            case .char("/"):
                searching = true
                search = ""
            default:
                break
            }
        }
    }

    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig) { _ in
                FileHandle.standardOutput.write(Data(
                    (ANSI.showCursor + ANSI.exitAltScreen).utf8))
                _exit(130)
            }
        }
    }

    // MARK: - Modal input

    /// Returns a non-nil outcome only when the user has fully confirmed.
    private func handleConfirmKey(
        _ key: Terminal.Key, mode: RemovalMode, typed: String
    ) -> Outcome? {
        switch key {
        case .escape, .char("q"):
            modal = .none
            status = "cancelled"
            return nil

        case .char("m"), .tab:
            let all = RemovalMode.allCases
            let next = all[(all.firstIndex(of: mode)! + 1) % all.count]
            // Switching mode clears any typed confirmation: the word was
            // consent for the *previous* mode, not this one.
            modal = .confirmApply(mode: next, typed: "")
            return nil

        case .enter:
            // The irreversible mode needs the word typed out in full. A
            // single keystroke is too cheap for an action with no undo.
            if mode == .delete, typed != "delete" {
                status = "type the word delete to confirm"
                return nil
            }
            modal = .none
            return .apply(paths: Array(selected), mode: mode)

        case .backspace:
            if case .confirmApply(let m, var t) = modal, !t.isEmpty {
                t.removeLast()
                modal = .confirmApply(mode: m, typed: t)
            }
            return nil

        case .char(let c):
            guard mode == .delete else { return nil }
            modal = .confirmApply(mode: mode, typed: typed + String(c))
            return nil

        default:
            return nil
        }
    }

    private func handleSearchKey(_ key: Terminal.Key) -> Bool {
        switch key {
        case .enter, .escape:
            searching = false
            return true
        case .backspace:
            if !search.isEmpty { search.removeLast() }
        case .char(let c):
            search.append(c)
        default:
            return false
        }
        refilter()
        return true
    }

    // MARK: - State transitions

    private func cycleTier() {
        let idx = tierCycle.firstIndex(where: { $0 == tierFilter }) ?? 0
        tierFilter = tierCycle[(idx + 1) % tierCycle.count]
        refilter()
    }

    private func refilter() {
        rows = Self.visibleRows(result.candidates, tier: tierFilter, search: search)
        cursor = min(cursor, max(0, rows.count - 1))
        clampScroll()
    }

    private static func visibleRows(_ all: [Candidate], tier: Tier?, search: String) -> [Candidate] {
        var out = all
        if let tier { out = out.filter { $0.tier == tier } }
        if !search.isEmpty {
            let needle = search.lowercased()
            out = out.filter {
                $0.name.lowercased().contains(needle)
                    || $0.path.lowercased().contains(needle)
                    || ($0.owner?.name?.lowercased().contains(needle) ?? false)
            }
        }
        return out
    }

    private func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        cursor = max(0, min(rows.count - 1, cursor + delta))
        clampScroll()
    }

    private func clampScroll() {
        let height = listHeight()
        if cursor < scroll { scroll = cursor }
        if cursor >= scroll + height { scroll = cursor - height + 1 }
        scroll = max(0, min(scroll, max(0, rows.count - height)))
    }

    /// Why a row cannot be selected, or nil if it can.
    private func refusalReason(_ c: Candidate) -> String? {
        if c.tier == .protected { return "protected — bleach will not act on this path" }
        if c.requiresRoot { return "outside your home; needs sudo — bleach will not act on it" }
        if c.supersededByChildren { return "contains finer-grained rows; select those instead" }
        return nil
    }

    private func toggleSelection() {
        guard let c = current else { return }
        if let reason = refusalReason(c) {
            status = reason
            return
        }
        if selected.contains(c.path) {
            selected.remove(c.path)
        } else {
            selected.insert(c.path)
        }
        move(1)
    }

    private func selectAllVisible() {
        let eligible = rows.filter { refusalReason($0) == nil }
        guard !eligible.isEmpty else {
            status = "nothing selectable in this view"
            return
        }
        for c in eligible { selected.insert(c.path) }
        let skipped = rows.count - eligible.count
        status = "selected \(eligible.count) rows"
            + (skipped > 0 ? " (\(skipped) not selectable)" : "")
    }

    private var current: Candidate? {
        rows.indices.contains(cursor) ? rows[cursor] : nil
    }

    private var selectedCandidates: [Candidate] {
        result.candidates.filter { selected.contains($0.path) }
    }

    private var selectedBytes: Int64 {
        selectedCandidates.reduce(0) { $0 + $1.sizeBytes }
    }

    private func listHeight() -> Int {
        max(3, terminal.size.rows - 13)
    }

    // MARK: - Render

    private func render() {
        let size = terminal.size
        var screen = Screen(rows: size.rows, cols: size.cols)
        let width = size.cols

        renderHeader(&screen, width: width)
        switch modal {
        case .help:
            renderHelp(&screen, width: width)
        case .confirmApply(let mode, let typed):
            renderConfirm(&screen, width: width, mode: mode, typed: typed)
        case .none:
            renderList(&screen, width: width)
            renderDetail(&screen, width: width)
        }
        renderFooter(&screen, width: width, totalRows: size.rows)
        screen.flush { terminal.write($0) }
    }

    private func renderHeader(_ screen: inout Screen, width: Int) {
        screen.put(" " + ANSI.bold("bleach")
            + ANSI.grey("  \(result.candidates.count) paths · "
                + "\(ByteFormat.short(result.totalBytes).trimmingCharacters(in: .whitespaces)) measured")
            + (selected.isEmpty ? "" :
                "   " + ANSI.green("\(selected.count) selected · "
                    + ByteFormat.short(selectedBytes).trimmingCharacters(in: .whitespaces))))

        var chips: [String] = []
        for tier in [Tier.cacheSafe, .orphanLikely, .review, .protected, .unknown] {
            let bytes = result.bytes(tier: tier)
            guard bytes > 0 else { continue }
            let text = "\(tier.label) \(ByteFormat.short(bytes).trimmingCharacters(in: .whitespaces))"
            chips.append(tierFilter == tier ? ANSI.inverse(" \(text) ") : " " + colorFor(tier, text) + " ")
        }
        screen.put(" " + chips.joined(separator: ANSI.grey("·")))

        if searching || !search.isEmpty {
            screen.put(" " + ANSI.cyan("/") + search + (searching ? ANSI.inverse(" ") : ""))
        } else if result.needsFullDiskAccess {
            screen.put(" " + ANSI.yellow("! \(result.accessDeniedCount) paths unreadable — grant Full Disk Access for true sizes"))
        } else {
            screen.blank()
        }

        screen.put(ANSI.grey(" " + Screen.padVisible("TIER", to: 11)
            + Screen.padVisible("SIZE", to: 7)
            + Screen.padVisible("AGE", to: 7)
            + Screen.padVisible("WHERE", to: 15)
            + "NAME"))
    }

    private func renderList(_ screen: inout Screen, width: Int) {
        let height = listHeight()
        guard !rows.isEmpty else {
            screen.put(ANSI.grey("   no rows match this filter"))
            screen.fill(upTo: 4 + height)
            return
        }

        let nameWidth = max(16, width - 42)
        for offset in 0..<height {
            let idx = scroll + offset
            guard idx < rows.count else { screen.blank(); continue }
            let c = rows[idx]
            let mark = selected.contains(c.path) ? ANSI.green("●")
                : (refusalReason(c) != nil ? ANSI.grey("·") : " ")

            var line = mark
                + colorFor(c.tier, Screen.padVisible(c.tier.label, to: 10))
                + Screen.padVisible(ByteFormat.short(c.sizeBytes), to: 7)
                + Screen.padVisible(ByteFormat.age(c.newestMTime), to: 7)
                + ANSI.grey(Screen.padVisible(ANSI.truncateTail(c.rootID, to: 14), to: 15))
                + ANSI.truncateTail(displayName(c), to: nameWidth)

            if c.requiresRoot { line += ANSI.grey(" ⚿") }
            if c.supersededByChildren { line += ANSI.grey(" ⊂") }

            screen.put(idx == cursor
                ? ANSI.inverse(Screen.padVisible(line, to: width - 1))
                : " " + line)
        }
    }

    private func renderDetail(_ screen: inout Screen, width: Int) {
        screen.put(ANSI.grey(String(repeating: "─", count: max(1, width))))
        guard let c = current else { screen.fill(upTo: screen.rows - 2); return }

        let owner = c.owner.map { rec -> String in
            let label = rec.name ?? rec.bundleID ?? "?"
            let sources = rec.sources.map(\.rawValue).sorted().joined(separator: "+")
            return rec.presenceConfidence >= 0.4
                ? "\(label) " + ANSI.grey("[\(sources)]")
                : ANSI.yellow("\(label) — identified but not installed ") + ANSI.grey("[\(sources)]")
        } ?? ANSI.grey("unresolved")

        screen.put(" " + ANSI.bold(ANSI.truncateHead(c.path, to: width - 2)))
        screen.put(" " + ANSI.grey("owner: ") + owner + ANSI.grey("   files: \(c.fileCount)"))

        // The evidence trail is the point of the whole tool: never show a
        // tier without the reasons behind it.
        let notes = c.evidence.filter { !$0.detail.hasPrefix("tiered ") }
        for e in notes.prefix(4) {
            let tag = e.weight > 0 ? ANSI.green("keep ")
                : (e.weight < 0 ? ANSI.yellow("clean") : ANSI.grey("info "))
            screen.put("   " + tag + " " + ANSI.grey(ANSI.truncateTail(e.detail, to: width - 10)))
        }
        if notes.count > 4 {
            screen.put("   " + ANSI.grey("… \(notes.count - 4) more signals"))
        }
        screen.fill(upTo: screen.rows - 2)
    }

    /// The confirmation overlay. States the mode, what it does in words, and
    /// the largest paths affected — so consent is informed rather than reflexive.
    private func renderConfirm(
        _ screen: inout Screen, width: Int, mode: RemovalMode, typed: String
    ) {
        let bytes = ByteFormat.short(selectedBytes).trimmingCharacters(in: .whitespaces)
        screen.blank()
        screen.put("   " + ANSI.bold("Apply to \(selected.count) paths · \(bytes)"))
        screen.blank()

        for candidate in RemovalMode.allCases {
            let isActive = candidate == mode
            let bullet = isActive ? ANSI.bold("▸ ") : "  "
            let name = Screen.padVisible(candidate.label, to: 16)
            let styled = isActive
                ? (candidate == .delete ? ANSI.red(ANSI.bold(name)) : ANSI.bold(name))
                : ANSI.grey(name)
            screen.put("   " + bullet + styled + ANSI.grey(candidate.summary))
        }

        screen.blank()
        for c in selectedCandidates.sorted(by: { $0.sizeBytes > $1.sizeBytes }).prefix(5) {
            screen.put("     " + ANSI.grey(Screen.padVisible(ByteFormat.short(c.sizeBytes), to: 8)
                + ANSI.truncateHead(c.path, to: max(20, width - 16))))
        }
        if selected.count > 5 {
            screen.put("     " + ANSI.grey("… \(selected.count - 5) more"))
        }
        screen.blank()

        if mode == .delete {
            screen.put("   " + ANSI.red(ANSI.bold("No undo. \(bytes) will be unlinked immediately.")))
            screen.put("   type " + ANSI.bold("delete") + " to confirm: "
                + typed + ANSI.inverse(" "))
        } else {
            screen.put("   " + ANSI.grey("Reversible: ") + mode.summary)
        }
        screen.fill(upTo: screen.rows - 2)
    }

    private func renderHelp(_ screen: inout Screen, width: Int) {
        let help: [(String, String)] = [
            ("j / k, ↑ ↓", "move"),
            ("ctrl-f / ctrl-b", "page"),
            ("g / G", "first / last"),
            ("space", "select row"),
            ("a", "select everything selectable in this view"),
            ("c", "clear selection"),
            ("t", "cycle tier filter"),
            ("/", "search name, path or owner"),
            ("w", "write a plan file and exit"),
            ("x", "apply now — choose quarantine, Trash, or delete"),
            ("?", "toggle this help"),
            ("q", "quit"),
        ]
        screen.blank()
        for (keys, description) in help {
            screen.put("   " + ANSI.bold(Screen.padVisible(keys, to: 18)) + ANSI.grey(description))
        }
        screen.blank()
        screen.put("   " + ANSI.grey("Rows marked ") + ANSI.grey("·")
            + ANSI.grey(" cannot be selected: protected, outside $HOME (⚿),"))
        screen.put("   " + ANSI.grey("or superseded by finer-grained rows (⊂)."))
        screen.fill(upTo: screen.rows - 2)
    }

    private func renderFooter(_ screen: inout Screen, width: Int, totalRows: Int) {
        screen.fill(upTo: totalRows - 1)
        let left: String
        let right: String

        if case .confirmApply(let mode, _) = modal {
            left = " " + ANSI.grey("mode=\(mode.rawValue)")
            right = ANSI.grey("m cycle mode · enter confirm · esc cancel")
        } else {
            let position = rows.isEmpty ? "0/0" : "\(cursor + 1)/\(rows.count)"
            left = " " + ANSI.grey(position)
                + (tierFilter == nil ? "" : ANSI.grey("  tier=\(tierFilter!.label)"))
            right = status.isEmpty
                ? ANSI.grey("space select · a all · t tier · / search · w plan · x apply · ? help · q quit")
                : ANSI.yellow(status)
        }

        let gap = max(1, width - Screen.visibleWidth(left) - Screen.visibleWidth(right) - 1)
        screen.put(left + String(repeating: " ", count: gap) + right)
        status = ""
    }

    private func displayName(_ c: Candidate) -> String {
        if let plugin = c.pluginName { return c.name + ANSI.grey("  ·\(plugin)") }
        return c.name
    }

    private func colorFor(_ tier: Tier, _ text: String) -> String {
        switch tier {
        case .protected: return ANSI.grey(text)
        case .cacheSafe: return ANSI.green(text)
        case .orphanLikely: return ANSI.yellow(text)
        case .review: return ANSI.cyan(text)
        case .unknown: return ANSI.dim(text)
        }
    }
}
