import Foundation

public enum ScanRootKind: String, Codable, Sendable, CaseIterable {
    /// Regenerable by definition. Safe to clear for *installed* owners too.
    case cache
    /// App state. May contain user data — never blanket-clean.
    case state
    /// Sandbox container. Bundle-ID named ones resolve directly; UUID-named
    /// ones are unreadable without entitlements and are always protected.
    case container
    case preference
    case log
    case savedState
    case launchAgent

    /// Whether clearing this is expected to be non-destructive when the owner
    /// is still installed.
    public var regenerable: Bool { self == .cache || self == .savedState || self == .log }
}

/// Which children of a root become candidates.
public enum EntryFilter: String, Sendable {
    case all
    /// Only `.`-prefixed directories. Used for `~` itself, where the
    /// interesting state is in dotdirs and everything else is user documents.
    case dotDirectoriesOnly
}

public struct ScanRoot: Sendable {
    public var id: String
    public var path: String
    public var kind: ScanRootKind
    /// Whether candidates are the direct children (`true`) or the root itself.
    public var enumerateChildren: Bool
    /// Children matching these names are *containers of containers*: bleach
    /// descends one extra level so per-version state (e.g. JetBrains
    /// `IntelliJIdea2025.3`) becomes its own candidate rather than being
    /// hidden inside a single 5 GB blob.
    public var multiTenantChildren: Set<String>
    public var filter: EntryFilter
    /// Outside the user's home, so acting on it would need root. bleach
    /// measures and attributes these paths but will never put one in a plan:
    /// a tool that can `rm -rf` in /Library as root is a categorically
    /// different risk than one confined to $HOME.
    public var requiresRoot: Bool
    /// Child names to skip. Used to stop the `~` dotdir root from
    /// double-counting `.cache` and `.local`, which are separate roots.
    public var excludeChildren: Set<String>

    public init(
        id: String,
        path: String,
        kind: ScanRootKind,
        enumerateChildren: Bool = true,
        multiTenantChildren: Set<String> = [],
        filter: EntryFilter = .all,
        excludeChildren: Set<String> = [],
        requiresRoot: Bool = false
    ) {
        self.id = id
        self.path = path
        self.kind = kind
        self.enumerateChildren = enumerateChildren
        self.multiTenantChildren = multiTenantChildren
        self.filter = filter
        self.excludeChildren = excludeChildren
        self.requiresRoot = requiresRoot
    }
}

public enum ScanRoots {
    /// Vendors that shard state by product and version under one umbrella
    /// directory. These are where "app installed but old version's state is
    /// dead weight" lives.
    public static let defaultMultiTenant: Set<String> = [
        "JetBrains", "Google", "Adobe", "Microsoft", "Mozilla", "Apple",
        "Steam", "Chromium", "CEF", "Electron", "Code", "Code - Insiders",
        "VisualStudio", "Unity", "Autodesk", "Sublime Text", "Sublime Text 3",
    ]

    public static func userDefaults(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> [ScanRoot] {
        let lib = home.appendingPathComponent("Library")
        func p(_ c: String) -> String { lib.appendingPathComponent(c).path }
        return [
            ScanRoot(id: "app-support", path: p("Application Support"), kind: .state,
                     multiTenantChildren: defaultMultiTenant),
            ScanRoot(id: "caches", path: p("Caches"), kind: .cache,
                     multiTenantChildren: defaultMultiTenant),
            ScanRoot(id: "containers", path: p("Containers"), kind: .container),
            ScanRoot(id: "group-containers", path: p("Group Containers"), kind: .container),
            ScanRoot(id: "http-storages", path: p("HTTPStorages"), kind: .cache),
            ScanRoot(id: "webkit", path: p("WebKit"), kind: .cache),
            ScanRoot(id: "saved-state", path: p("Saved Application State"), kind: .savedState),
            ScanRoot(id: "logs", path: p("Logs"), kind: .log),
            ScanRoot(id: "preferences", path: p("Preferences"), kind: .preference),
            ScanRoot(id: "app-scripts", path: p("Application Scripts"), kind: .state),
            ScanRoot(id: "launch-agents", path: p("LaunchAgents"), kind: .launchAgent),

            // Not everything lives in ~/Library. Tooling installed outside the
            // app-bundle world keeps state in XDG-ish directories and dotdirs,
            // and it is not small: opencode alone holds 2.8 GB in
            // ~/.local/share, which a Library-only scan never sees.
            ScanRoot(id: "xdg-cache", path: home.appendingPathComponent(".cache").path,
                     kind: .cache, multiTenantChildren: defaultMultiTenant),
            ScanRoot(id: "xdg-data", path: home.appendingPathComponent(".local/share").path,
                     kind: .state),
            ScanRoot(id: "xdg-state", path: home.appendingPathComponent(".local/state").path,
                     kind: .state),
            ScanRoot(id: "dotdirs", path: home.path, kind: .state,
                     filter: .dotDirectoriesOnly,
                     excludeChildren: [".cache", ".local", ".config", ".Trash"]),
        ] + systemRoots()
    }

    /// System-level application state. Reported with full evidence so the
    /// reclaimable total is honest, but never actionable — see
    /// `ScanRoot.requiresRoot`. Much of this is unreadable without root, so
    /// sizes here are undercounts by default.
    public static func systemRoots() -> [ScanRoot] {
        [
            ScanRoot(id: "sys-app-support", path: "/Library/Application Support",
                     kind: .state, multiTenantChildren: defaultMultiTenant,
                     requiresRoot: true),
            ScanRoot(id: "sys-caches", path: "/Library/Caches",
                     kind: .cache, requiresRoot: true),
            ScanRoot(id: "sys-logs", path: "/Library/Logs",
                     kind: .log, requiresRoot: true),
        ]
    }
}
