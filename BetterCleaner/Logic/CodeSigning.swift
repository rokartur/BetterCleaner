import Foundation
import Security

/// Reads the Apple Developer Team Identifier from a signed bundle/executable.
///
/// The Team ID is ownership evidence the file system doesn't carry: two apps in
/// the same reverse-DNS namespace (`com.foo.*`) can belong to different vendors,
/// and a look-alike leftover named after an app can be a wholly different
/// publisher's bundle. Comparing Team IDs lets a scan reject a signed bundle whose
/// team differs from the app being removed, without guessing from the name.
enum CodeSigning {
    /// The lowercased Team Identifier of the code at `url`, or nil if it is
    /// unsigned, ad-hoc signed (no team), or unreadable. Reads the on-disk
    /// signature (no validation of the running process) — safe to call for any
    /// bundle path.
    static func teamID(of url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(rawValue: 0), &staticCode) == errSecSuccess,
              let code = staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let team = dict[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty else { return nil }
        return team.lowercased()
    }
}
