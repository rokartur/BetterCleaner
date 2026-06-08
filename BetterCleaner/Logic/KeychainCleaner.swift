import Foundation
import Security

/// Removes an app's own Keychain credentials during a complete uninstall.
///
/// Deliberately conservative: it matches only on the app's reverse-DNS bundle
/// ids (never the display name), and only items whose service/label/server
/// actually contains one of those ids. So uninstalling an app named "Mail" can
/// never sweep a "Gmail" web login — only items the app itself created under its
/// bundle id are removed.
enum KeychainCleaner {
    /// Delete matching generic + internet password items. Returns the count
    /// removed. Items the OS won't let us touch are skipped silently.
    @discardableResult
    static func deleteItems(matching descriptor: AppDescriptor) -> Int {
        // Require a real reverse-DNS id (has a dot, reasonably long) so a short or
        // empty id can't match broadly. Lowercased to match the lowercased
        // haystack below (allBundleIDs is already lowercased; explicit for safety).
        let needles = descriptor.allBundleIDs
            .map { $0.lowercased() }
            .filter { $0.count >= 8 && $0.contains(".") }
        guard !needles.isEmpty else { return 0 }

        var deleted = 0
        for kClass in [kSecClassGenericPassword, kSecClassInternetPassword] {
            deleted += deleteMatching(itemClass: kClass, needles: needles)
        }
        return deleted
    }

    private static func deleteMatching(itemClass: CFString, needles: [String]) -> Int {
        let query: [String: Any] = [
            kSecClass as String: itemClass,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return 0 }

        var count = 0
        for attrs in items {
            let service = (attrs[kSecAttrService as String] as? String)?.lowercased() ?? ""
            let label = (attrs[kSecAttrLabel as String] as? String)?.lowercased() ?? ""
            let server = (attrs[kSecAttrServer as String] as? String)?.lowercased() ?? ""
            let haystack = service + "\n" + label + "\n" + server
            guard needles.contains(where: { haystack.contains($0) }) else { continue }

            // Build a precise delete query from this item's identifying attributes
            // so exactly the matched entry is removed.
            var delete: [String: Any] = [kSecClass as String: itemClass]
            if let s = attrs[kSecAttrService as String] { delete[kSecAttrService as String] = s }
            if let a = attrs[kSecAttrAccount as String] { delete[kSecAttrAccount as String] = a }
            if let srv = attrs[kSecAttrServer as String] { delete[kSecAttrServer as String] = srv }
            if let proto = attrs[kSecAttrProtocol as String] { delete[kSecAttrProtocol as String] = proto }
            if SecItemDelete(delete as CFDictionary) == errSecSuccess { count += 1 }
        }
        return count
    }
}
