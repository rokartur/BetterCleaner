import Foundation

/// Advisory CVE scan for installed Homebrew packages, backed by the free OSV.dev
/// query API. For each package it asks OSV whether the installed version has known
/// vulnerabilities.
///
/// This is **advisory**: it needs outbound network access and depends on OSV's
/// coverage of the Homebrew ecosystem, so an empty result means "nothing found",
/// not "definitely safe". A network failure on the very first request fails the whole
/// scan so the UI can tell the user it needs internet.
enum HomebrewVulnScanner {
    struct Vulnerability {
        let packageToken: String
        let id: String          // CVE / GHSA id
        let summary: String
        let severity: String
        let fixedIn: String
    }

    enum ScanError: Error { case offline }

    private static let endpoint = URL(string: "https://api.osv.dev/v1/query")!

    /// Scan `packages` sequentially. `progress(done, total)` and `completion` are
    /// delivered on the main queue. Stops early when `isCancelled()` becomes true.
    static func scan(packages: [HomebrewPackage],
                     progress: @escaping (Int, Int) -> Void,
                     isCancelled: @escaping () -> Bool,
                     completion: @escaping (Result<[Vulnerability], ScanError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var found: [Vulnerability] = []
            let total = packages.count
            for (index, pkg) in packages.enumerated() {
                if isCancelled() { break }
                guard !pkg.installedVersion.isEmpty else {
                    report(progress, index + 1, total)
                    continue
                }
                let (vulns, error) = query(token: pkg.token, version: pkg.installedVersion)
                // Treat a failure on the first package as "no connectivity".
                if let error, index == 0, vulns.isEmpty, isLikelyOffline(error) {
                    DispatchQueue.main.async { completion(.failure(.offline)) }
                    return
                }
                found += vulns.map { v in
                    Vulnerability(
                        packageToken: pkg.token,
                        id: v.id,
                        summary: v.summary ?? v.details ?? "",
                        severity: v.severity?.first?.score ?? "unknown",
                        fixedIn: v.affected?.compactMap { $0.ranges?.compactMap { $0.events?.compactMap(\.fixed).first }.first }.first ?? ""
                    )
                }
                report(progress, index + 1, total)
            }
            let result = found
            DispatchQueue.main.async { completion(.success(result)) }
        }
    }

    private static func report(_ progress: @escaping (Int, Int) -> Void, _ done: Int, _ total: Int) {
        DispatchQueue.main.async { progress(done, total) }
    }

    private static func isLikelyOffline(_ error: Error) -> Bool {
        let code = (error as NSError).code
        return [NSURLErrorNotConnectedToInternet,
                NSURLErrorCannotConnectToHost,
                NSURLErrorCannotFindHost,
                NSURLErrorNetworkConnectionLost,
                NSURLErrorTimedOut].contains(code)
    }

    // MARK: - OSV request (synchronous within the background queue)

    private static func query(token: String, version: String) -> (vulns: [OSVVuln], error: Error?) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 12
        let body: [String: Any] = [
            "version": version,
            "package": ["name": token, "ecosystem": "Homebrew"],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let semaphore = DispatchSemaphore(value: 0)
        var vulns: [OSVVuln] = []
        var failure: Error?
        let task = URLSession.shared.dataTask(with: request) { data, _, error in
            defer { semaphore.signal() }
            if let error { failure = error; return }
            guard let data, let decoded = try? JSONDecoder().decode(OSVResponse.self, from: data) else { return }
            vulns = decoded.vulns ?? []
        }
        task.resume()
        semaphore.wait()
        return (vulns, failure)
    }

    // MARK: - OSV response decoding

    private struct OSVResponse: Decodable { let vulns: [OSVVuln]? }
    struct OSVVuln: Decodable {
        let id: String
        let summary: String?
        let details: String?
        let severity: [OSVSeverity]?
        let affected: [OSVAffected]?
    }
    struct OSVSeverity: Decodable { let type: String; let score: String }
    struct OSVAffected: Decodable { let ranges: [OSVRange]? }
    struct OSVRange: Decodable { let events: [OSVEvent]? }
    struct OSVEvent: Decodable { let fixed: String? }
}
