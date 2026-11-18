import Foundation

public enum ProxyHelperConstants {
    public static let machServiceName = "com.clashbar.helper"
    public static let daemonPlistName = "com.clashbar.helper.plist"
    public static let helperBundleProgram = "Contents/Library/HelperTools/com.clashbar.helper"
    public static let helperBundlePlist = "Contents/Library/LaunchDaemons/com.clashbar.helper.plist"
    public static let installedHelperPath = "/Library/PrivilegedHelperTools/com.clashbar.helper"
    public static let installedPlistPath = "/Library/LaunchDaemons/com.clashbar.helper.plist"
    public static let installedVersionPath = "/Library/PrivilegedHelperTools/com.clashbar.helper.version"
    public static let helperVersion = 2
    public static let allowedClientBundleIdentifier = "com.clashbar"

    /// Requirement used when the helper itself is adhoc-signed (local or unsigned builds).
    ///
    /// There is no certificate to anchor against in that case, so the bundle identifier in the
    /// signature is all that can be verified. Any process running as the same user can satisfy
    /// this by adhoc-signing itself as `com.clashbar`, which is why signed builds must not use it.
    public static let allowedClientRequirement = "identifier \"\(allowedClientBundleIdentifier)\""

    /// Requirement used when the helper carries a Team ID (Developer ID signed builds).
    ///
    /// `anchor apple generic` is the part that actually matters: on its own,
    /// `certificate leaf[subject.OU]` only compares a subject field, and a self-signed
    /// certificate can contain any OU the attacker likes.
    public static func signedClientRequirement(teamID: String) -> String {
        "anchor apple generic and identifier \"\(allowedClientBundleIdentifier)\""
            + " and certificate leaf[subject.OU] = \"\(teamID)\""
    }
}

@objc(ProxyHelperProtocol)
public protocol ProxyHelperProtocol {
    func ping(completion: @escaping (Bool, String?) -> Void)
    func setSystemProxy(
        host: String,
        httpPort: Int,
        httpsPort: Int,
        socksPort: Int,
        completion: @escaping (Bool, String?) -> Void)
    func clearSystemProxy(completion: @escaping (Bool, String?) -> Void)
    func getSystemProxyState(completion: @escaping (Bool, Bool, String?) -> Void)
    func getSystemProxyActiveTarget(completion: @escaping (Bool, String?, Int, String?) -> Void)
    func isSystemProxyConfigured(
        host: String,
        httpPort: Int,
        httpsPort: Int,
        socksPort: Int,
        completion: @escaping (Bool, Bool, String?) -> Void)
    func getSystemProxyExceptions(completion: @escaping (Bool, String?, String?) -> Void)
    func setSystemProxyExceptions(serializedExceptions: String, completion: @escaping (Bool, String?) -> Void)
}
