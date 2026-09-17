import Foundation

/// Discovers, validates, and invokes plugins.
///
/// Every path a plugin returns is re-validated before bleach will even
/// measure it, let alone propose it:
///
///  1. absolute, and existing on disk
///  2. inside the user's home
///  3. inside at least one of the plugin's declared `owns` prefixes
///  4. unchanged by path standardisation (blocks `..` traversal)
///  5. not a symlink (blocks pointing at something else entirely)
///
/// A plugin that violates these is not an error to recover from — the paths
/// are dropped and the reason is recorded.
public struct PluginHost: Sendable {
    public struct Loaded: Sendable {
        public var manifest: PluginManifest
        public var executable: String
        public var ownsExpanded: [String]
    }

    public struct Warning: Sendable {
        public var plugin: String
        public var message: String
    }

    public var plugins: [Loaded] = []
    public var warnings: [Warning] = []
    let home: String
    let timeout: TimeInterval

    public init(home: String = NSHomeDirectory(), timeout: TimeInterval = 20) {
        self.home = home
        self.timeout = timeout
    }

    public static func searchPaths(home: String = NSHomeDirectory()) -> [String] {
        var paths = ["\(home)/.config/bleach/plugins"]
        if let env = ProcessInfo.processInfo.environment["BLEACH_PLUGIN_PATH"] {
            paths += env.split(separator: ":").map(String.init)
        }
        // Repo-local plugins, so `swift run bleach` picks up the bundled
        // examples without an install step.
        paths.append(FileManager.default.currentDirectoryPath + "/plugins")
        return paths
    }

    // MARK: - Discovery

    public mutating func discover() {
        let fm = FileManager.default
        var seen = Set<String>()

        for dir in Self.searchPaths(home: home) {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries.sorted() where !entry.hasPrefix(".") {
                let path = "\(dir)/\(entry)"
                // A plugin is either an executable file, or a directory
                // containing an executable named `plugin`.
                var exe = path
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                    exe = "\(path)/plugin"
                }
                guard fm.isExecutableFile(atPath: exe) else { continue }

                let result = Shell.run(exe, ["manifest"], timeout: 10)
                guard result.ok, let data = result.stdout.data(using: .utf8) else {
                    warnings.append(Warning(plugin: entry,
                        message: "manifest failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"))
                    continue
                }
                guard let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data) else {
                    warnings.append(Warning(plugin: entry, message: "manifest is not valid protocol JSON"))
                    continue
                }
                guard manifest.protocolVersion == PluginProtocolVersion.current else {
                    warnings.append(Warning(plugin: manifest.name,
                        message: "speaks protocol \(manifest.protocolVersion), bleach speaks \(PluginProtocolVersion.current)"))
                    continue
                }
                guard seen.insert(manifest.name).inserted else { continue }
                guard !manifest.owns.isEmpty else {
                    warnings.append(Warning(plugin: manifest.name, message: "declares no owns: scope; ignored"))
                    continue
                }
                plugins.append(Loaded(
                    manifest: manifest,
                    executable: exe,
                    ownsExpanded: manifest.expandedOwns(home: home)
                ))
            }
        }
    }

    // MARK: - Enumerate

    /// Ask each plugin for candidates inside its own scope. Returns
    /// unmeasured candidates — bleach measures them itself rather than
    /// trusting a plugin's size claims.
    public mutating func enumerate(staleDays: Int) -> [Candidate] {
        var out: [Candidate] = []
        let fm = FileManager.default

        for plugin in plugins where plugin.manifest.canEnumerate {
            let scope = plugin.ownsExpanded.filter { fm.fileExists(atPath: $0) }
            guard !scope.isEmpty else { continue }

            let request = PluginEnumerateRequest(home: home, staleDays: staleDays, scope: scope)
            guard let response: PluginEnumerateResponse = call(plugin, "enumerate", request) else { continue }

            for pc in response.candidates {
                guard let validated = validate(pc.path, for: plugin) else { continue }
                var evidence = (pc.evidence ?? []).map { $0.toEvidence(pluginName: plugin.manifest.name) }
                evidence.append(Evidence(.aliasMatch,
                    "surfaced by plugin \(plugin.manifest.name)", weight: 0))

                out.append(Candidate(
                    path: validated,
                    name: pc.label ?? (validated as NSString).lastPathComponent,
                    rootID: "plugin:\(plugin.manifest.name)",
                    kind: pc.kind == "cache" ? .cache : .state,
                    isDirectory: isDirectory(validated),
                    evidence: evidence,
                    tier: Tier.fromHint(pc.tierHint) ?? .unknown
                ))
            }
        }
        return out
    }

    // MARK: - Resolve

    /// Let plugins contribute evidence for candidates bleach already found.
    /// Only candidates inside a plugin's scope are shown to it — a plugin
    /// never sees a listing of the whole Library.
    public mutating func resolve(_ candidates: [Candidate], staleDays: Int) -> [String: (Tier?, [Evidence], String?, String?)] {
        var merged: [String: (Tier?, [Evidence], String?, String?)] = [:]

        for plugin in plugins where plugin.manifest.canResolve {
            let inScope = candidates.filter { c in
                plugin.ownsExpanded.contains { c.path == $0 || c.path.hasPrefix($0 + "/") }
            }
            guard !inScope.isEmpty else { continue }

            let request = PluginResolveRequest(
                home: home,
                staleDays: staleDays,
                candidates: inScope.map {
                    PluginResolveRequest.Item(
                        path: $0.path, name: $0.name,
                        rootID: $0.rootID, sizeBytes: $0.sizeBytes)
                }
            )
            guard let response: PluginResolveResponse = call(plugin, "resolve", request) else { continue }

            for r in response.resolutions {
                guard let validated = validate(r.path, for: plugin) else { continue }
                let evidence = (r.evidence ?? []).map { $0.toEvidence(pluginName: plugin.manifest.name) }
                var entry = merged[validated] ?? (nil, [], nil, nil)
                entry.1 += evidence
                if let hint = Tier.fromHint(r.tierHint) {
                    entry.0 = entry.0.map { Tier.mostProtective($0, hint) } ?? hint
                }
                entry.2 = entry.2 ?? r.ownerName
                entry.3 = entry.3 ?? r.ownerBundleID
                merged[validated] = entry
            }
        }
        return merged
    }

    // MARK: - Plumbing

    private mutating func call<Req: Encodable, Res: Decodable>(
        _ plugin: Loaded, _ mode: String, _ request: Req
    ) -> Res? {
        guard let payload = try? JSONEncoder().encode(request) else { return nil }
        let result = ShellIO.run(plugin.executable, [mode], stdin: payload, timeout: timeout)
        guard result.ok else {
            warnings.append(Warning(plugin: plugin.manifest.name,
                message: "\(mode) failed (exit \(result.exitCode))"
                    + (result.timedOut ? ", timed out" : "")
                    + ": \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))"))
            return nil
        }
        guard let data = result.stdout.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Res.self, from: data) else {
            warnings.append(Warning(plugin: plugin.manifest.name,
                message: "\(mode) returned unparseable JSON"))
            return nil
        }
        return decoded
    }

    /// The five safety checks. Returns the standardised path, or nil.
    mutating func validate(_ raw: String, for plugin: Loaded) -> String? {
        func reject(_ why: String) -> String? {
            warnings.append(Warning(plugin: plugin.manifest.name,
                message: "dropped \(raw): \(why)"))
            return nil
        }
        guard raw.hasPrefix("/") else { return reject("not an absolute path") }
        let std = URL(fileURLWithPath: raw).standardizedFileURL.path
        guard std == raw.replacingOccurrences(of: "//", with: "/")
                .replacingOccurrences(of: "/./", with: "/") || std == raw else {
            return reject("path is not already standardised (possible traversal)")
        }
        guard std.hasPrefix(home + "/") else { return reject("outside the user's home") }
        guard plugin.ownsExpanded.contains(where: { std == $0 || std.hasPrefix($0 + "/") }) else {
            return reject("outside the plugin's declared owns: scope")
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: std) else { return reject("does not exist") }
        if let attrs = try? fm.attributesOfItem(atPath: std),
           attrs[.type] as? FileAttributeType == .typeSymbolicLink {
            return reject("is a symlink")
        }
        return std
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return isDir.boolValue
    }
}
