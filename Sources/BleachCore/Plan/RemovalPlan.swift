import Foundation

/// A reviewable, editable description of what `apply` will do.
///
/// Making the plan a separate artifact is the central design choice of the
/// tool: scanning is heuristic, so the heuristics' output gets written down,
/// read by a human, and only then executed. `apply` does no analysis of its
/// own beyond refusing unsafe entries.
public struct RemovalPlan: Codable, Sendable {
    public static let currentVersion = 1

    public struct Entry: Codable, Sendable {
        public var path: String
        public var sizeBytes: Int64
        public var tier: Tier
        public var ownerLabel: String?
        public var newestMTime: Date?
        /// Human-readable justification, copied from the evidence trail so
        /// the plan is reviewable without re-running a scan.
        public var reasons: [String]

        public init(
            path: String, sizeBytes: Int64, tier: Tier,
            ownerLabel: String?, newestMTime: Date?, reasons: [String]
        ) {
            self.path = path
            self.sizeBytes = sizeBytes
            self.tier = tier
            self.ownerLabel = ownerLabel
            self.newestMTime = newestMTime
            self.reasons = reasons
        }
    }

    public var version: Int = RemovalPlan.currentVersion
    public var createdAt: Date
    public var home: String
    public var entries: [Entry]

    public var totalBytes: Int64 { entries.reduce(0) { $0 + $1.sizeBytes } }

    public init(createdAt: Date = Date(), home: String = NSHomeDirectory(), entries: [Entry]) {
        self.createdAt = createdAt
        self.home = home
        self.entries = entries
    }

    public static func from(candidates: [Candidate]) -> RemovalPlan {
        RemovalPlan(entries: candidates.map { c in
            Entry(
                path: c.path,
                sizeBytes: c.sizeBytes,
                tier: c.tier,
                ownerLabel: c.owner.flatMap { $0.name ?? $0.bundleID },
                newestMTime: c.newestMTime,
                reasons: c.evidence
                    .filter { $0.weight <= 0 }
                    .map { "\($0.kind.rawValue): \($0.detail)" }
            )
        })
    }

    // MARK: - Serialisation

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public func write(to path: String) throws {
        let data = try Self.encoder().encode(self)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    public static func read(from path: String) throws -> RemovalPlan {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let plan = try decoder().decode(RemovalPlan.self, from: data)
        guard plan.version == currentVersion else {
            throw BleachError.planVersionMismatch(found: plan.version, expected: currentVersion)
        }
        return plan
    }
}

public enum BleachError: Error, CustomStringConvertible {
    case planVersionMismatch(found: Int, expected: Int)
    case quarantineUnavailable(String)
    case restoreTargetOccupied(String)
    case notFound(String)

    public var description: String {
        switch self {
        case .planVersionMismatch(let found, let expected):
            return "plan is version \(found), this bleach understands \(expected)"
        case .quarantineUnavailable(let why):
            return "quarantine unavailable: \(why)"
        case .restoreTargetOccupied(let path):
            return "cannot restore: \(path) already exists"
        case .notFound(let what):
            return "not found: \(what)"
        }
    }
}
