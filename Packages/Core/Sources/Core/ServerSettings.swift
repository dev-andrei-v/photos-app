import Foundation
import Observation

/// Parsing of the server address the user types.
public enum ServerAddress {
    /// Prefilled at sign-in: the app's build setting (`CLOUD_DEFAULT_SERVER` in
    /// Config/Local.xcconfig), or none.
    public static let `default`: URL? =
        (Bundle.main.object(forInfoDictionaryKey: "CloudDefaultServer") as? String).flatMap(normalize)

    /// Parses user input such as `photos.example.com`, `192.168.1.10:2283` or `http://host:2283/api`.
    /// A trailing `/api` is removed (the client adds it). Without a scheme, a public name gets
    /// `https` and an address only a private network can reach gets `http`.
    public static func normalize(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let hasScheme = text.contains("://")
        if !hasScheme { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        if text.lowercased().hasSuffix("/api") { text.removeLast(4) }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return nil }
        if !hasScheme, !isPrivateHost(host) { components.scheme = "https" }
        return components.url
    }

    /// Hosts that are usually served over plain HTTP: IP numbers, short names (`pi`), `.local`
    /// names and Tailscale MagicDNS names (`*.ts.net`).
    static func isPrivateHost(_ host: String) -> Bool {
        let host = host.lowercased()
        if host.contains(":") { return true } // IPv6 number
        let labels = host.split(separator: ".")
        if labels.count <= 1 { return true }
        if labels.count == 4, labels.allSatisfy({ UInt8($0) != nil }) { return true }
        return host.hasSuffix(".local") || host.hasSuffix(".ts.net")
    }
}

@MainActor
@Observable
public final class ServerSettings {
    /// The one address the server is reached at. Shared by all accounts.
    public var address: URL? {
        didSet { persist() }
    }

    private let defaults: UserDefaults
    private static let key = "server.address"
    /// Earlier versions kept a home and an away address.
    private static let legacyKey = "server.addresses"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let text = defaults.string(forKey: Self.key) {
            address = URL(string: text)
        } else if let data = defaults.data(forKey: Self.legacyKey),
                  let legacy = try? JSONDecoder().decode(LegacyAddresses.self, from: data) {
            // The away address works everywhere, so it is the one kept.
            address = legacy.remote ?? legacy.local
            persist()
        } else {
            address = ServerAddress.default
        }
        defaults.removeObject(forKey: Self.legacyKey)
    }

    private func persist() {
        defaults.set(address?.absoluteString ?? "", forKey: Self.key)
    }

    private struct LegacyAddresses: Decodable {
        var local: URL?
        var remote: URL?
    }
}
