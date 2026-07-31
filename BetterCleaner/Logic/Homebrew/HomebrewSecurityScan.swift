import Foundation

/// Advisory CVE lookup for installed formulae against the OSV.dev database
/// (`POST /v1/querybatch`).
///
/// OSV has no Homebrew ecosystem, so packages are matched by bare name +
/// installed version across every ecosystem OSV indexes. A hit therefore means
/// "a project with this name and version has a known advisory", not proof the
/// brew build is affected — the UI must present results as advisory only.
/// Casks are skipped: they are apps with their own update channels, not OSS
/// builds OSV tracks. Offline or API failure surfaces as a thrown error the
/// caller renders as "scan unavailable" — never as a crash or empty success.
enum HomebrewSecurityScan {
    struct Finding: Equatable {
        let package: String
        let version: String
        let vulnerabilityIDs: [String]
    }

    struct Report: Equatable {
        let scannedCount: Int
        let findings: [Finding]
    }

    enum ScanError: LocalizedError, Equatable {
        case requestFailed(status: Int)

        var errorDescription: String? {
            switch self {
            case .requestFailed(let status): "OSV.dev request failed (HTTP \(status))."
            }
        }
    }

    struct Query: Encodable, Equatable {
        struct Package: Encodable, Equatable { let name: String }
        let package: Package
        let version: String
    }

    struct BatchResponse: Decodable {
        struct QueryResult: Decodable {
            struct Vulnerability: Decodable { let id: String }
            let vulns: [Vulnerability]?
        }
        let results: [QueryResult]
    }

    static let queryBatchURL = URL(string: "https://api.osv.dev/v1/querybatch")!
    /// OSV rejects batches above 1000 queries.
    static let batchLimit = 1000

    // MARK: - Pure builders / decoding (unit-tested)

    /// Installed formulae → OSV queries. Skips casks and version-less entries,
    /// and strips Homebrew's `_<revision>` suffix (`1.24.5_1` → `1.24.5`),
    /// which upstream version numbers never carry.
    static func queries(for packages: [HomebrewPackage]) -> [Query] {
        packages
            .filter { !$0.isCask && !$0.installedVersion.isEmpty }
            .map { Query(package: .init(name: $0.token), version: normalizedVersion($0.installedVersion)) }
    }

    static func normalizedVersion(_ version: String) -> String {
        guard let underscore = version.lastIndex(of: "_"),
              version[version.index(after: underscore)...].allSatisfy(\.isNumber),
              underscore != version.startIndex
        else { return version }
        return String(version[..<underscore])
    }

    /// Pair each query with its positional result; only queries with advisories
    /// become findings.
    static func findings(queries: [Query], results: [BatchResponse.QueryResult]) -> [Finding] {
        zip(queries, results).compactMap { query, result in
            guard let ids = result.vulns?.map(\.id), !ids.isEmpty else { return nil }
            return Finding(package: query.package.name, version: query.version, vulnerabilityIDs: ids)
        }
    }

    static func advisoryURL(_ id: String) -> String { "https://osv.dev/vulnerability/\(id)" }

    // MARK: - Execution

    /// Load installed packages and scan their formulae. Call from any context;
    /// brew and the network requests run off the main thread.
    static func run(session: URLSession = .shared) async throws -> Report {
        try await scan(try HomebrewService.installedPackages(), session: session)
    }

    static func scan(_ packages: [HomebrewPackage], session: URLSession = .shared) async throws -> Report {
        let all = queries(for: packages)
        var results: [BatchResponse.QueryResult] = []
        var start = 0
        while start < all.count {
            let chunk = Array(all[start ..< min(start + batchLimit, all.count)])
            start += batchLimit

            var request = URLRequest(url: queryBatchURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("BetterCleaner", forHTTPHeaderField: "User-Agent")
            request.httpBody = try JSONEncoder().encode(["queries": chunk])

            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw ScanError.requestFailed(status: http.statusCode)
            }
            results += try JSONDecoder().decode(BatchResponse.self, from: data).results
        }
        return Report(scannedCount: all.count, findings: findings(queries: all, results: results))
    }
}
