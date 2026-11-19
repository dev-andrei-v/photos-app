import Foundation

public struct ServerVersion: Comparable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// The Immich release `api/immich-openapi-specs.json` came from.
    public static let generatedFrom = ServerVersion(major: 3, minor: 3, patch: 5)

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: ServerVersion, rhs: ServerVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

public enum VersionCheck: Sendable, Equatable {
    /// The server is the version the spec came from, or a later release with the same major version.
    /// Immich keeps its API backwards compatible within a major version, so these need no warning
    /// (checked against 3.3.6 and 3.4.2: no change to any request or response the app uses).
    case supported
    /// The server has a newer major version, which may remove or change endpoints.
    case serverNewer(ServerVersion)
    /// The server is older than the spec; endpoints may be missing.
    case serverOlder(ServerVersion)

    public init(server: ServerVersion, client: ServerVersion = .generatedFrom) {
        if server < client {
            self = .serverOlder(server)
        } else if server.major > client.major {
            self = .serverNewer(server)
        } else {
            self = .supported
        }
    }

    public var warning: String? {
        switch self {
        case .supported:
            nil
        case .serverNewer(let version):
            "The Cloud server runs version \(version). This app was built for version \(ServerVersion.generatedFrom.major), so some features may not work until the app is updated."
        case .serverOlder(let version):
            "The Cloud server runs version \(version), older than \(ServerVersion.generatedFrom) which this app was built for. Update the server."
        }
    }
}

extension Client {
    /// Fetches `GET /server/version`.
    public func serverVersion() async throws -> ServerVersion {
        switch try await getServerVersion() {
        case .ok(let response):
            let dto = try response.body.json
            return ServerVersion(major: dto.major, minor: dto.minor, patch: dto.patch)
        case .undocumented(let status, let payload):
            throw await APIError.from(statusCode: status, payload: payload, operation: "server version")
        }
    }
}
