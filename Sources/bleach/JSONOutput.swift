import BleachCore
import Foundation

enum JSONOutput {
    struct Envelope: Codable {
        var scannedPaths: Int
        var totalBytes: Int64
        var elapsedSeconds: Double
        var accessDeniedCount: Int
        var inventorySummary: String
        var byTier: [String: TierSummary]
        var candidates: [Candidate]
    }

    struct TierSummary: Codable {
        var count: Int
        var bytes: Int64
    }

    static func emit(_ result: ScanResult, minSize: Int64) throws {
        var byTier: [String: TierSummary] = [:]
        for tier in Tier.allCases {
            let items = result.candidates.filter { $0.tier == tier }
            byTier[tier.rawValue] = TierSummary(
                count: items.count,
                bytes: items.reduce(0) { $0 + $1.sizeBytes }
            )
        }
        let envelope = Envelope(
            scannedPaths: result.candidates.count,
            totalBytes: result.totalBytes,
            elapsedSeconds: result.elapsed,
            accessDeniedCount: result.accessDeniedCount,
            inventorySummary: result.inventory.summary,
            byTier: byTier,
            candidates: result.candidates.filter { $0.sizeBytes >= minSize }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(envelope), as: UTF8.self))
    }
}
