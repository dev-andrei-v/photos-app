import Core
import Foundation

/// The server address that answered.
public struct ActiveServer: Sendable, Hashable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// False for addresses only this phone's VPN can reach (Tailscale: `*.ts.net` names and
    /// 100.64.0.0/10 numbers), which an AirPlay receiver can't open itself.
    public var isReachableByOtherDevices: Bool {
        guard let host = url.host()?.lowercased() else { return false }
        if host.hasSuffix(".ts.net") { return false }
        let numbers = host.split(separator: ".").compactMap { UInt8($0) }
        if numbers.count == 4, host.split(separator: ".").count == 4, numbers[0] == 100, (64...127).contains(numbers[1]) { return false }
        return true
    }
}

public enum ConnectionStatus: Sendable, Equatable {
    case unknown
    case checking
    case connected(ActiveServer)
    /// The server didn't answer. Each entry is a reason, e.g. "photos.example.com: timed out".
    case unreachable([String])

    public var activeServer: ActiveServer? {
        if case .connected(let server) = self { server } else { nil }
    }
}

/// Checks whether an address is a Cloud server that answers (each provider has its own ping).
public protocol ServerProber: Sendable {
    func ping(_ server: URL, timeout: Duration) async -> Result<Void, CloudError>
}

/// Checks that the configured address answers `/server/ping`.
/// Concurrent `resolve()` calls share one probe.
public actor ServerSelector {
    public typealias AddressSource = @Sendable () async -> URL?

    public private(set) var status: ConnectionStatus = .unknown

    private let prober: any ServerProber
    private let address: AddressSource
    private let timeout: Duration
    private var inFlight: Task<ConnectionStatus, Never>?
    private var continuations: [UUID: AsyncStream<ConnectionStatus>.Continuation] = [:]

    public init(
        prober: any ServerProber,
        timeout: Duration = .seconds(6),
        address: @escaping AddressSource
    ) {
        self.prober = prober
        self.address = address
        self.timeout = timeout
    }

    public var activeServer: ActiveServer? { status.activeServer }

    /// Emits the current status immediately, then every change.
    public func updates() -> AsyncStream<ConnectionStatus> {
        let (stream, continuation) = AsyncStream<ConnectionStatus>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        continuations[id] = continuation
        continuation.yield(status)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    @discardableResult
    public func resolve() async -> ConnectionStatus {
        if let inFlight { return await inFlight.value }
        let task = Task { await probe() }
        inFlight = task
        if status.activeServer == nil { publish(.checking) }
        let result = await task.value
        inFlight = nil
        publish(result)
        return result
    }

    private func probe() async -> ConnectionStatus {
        guard let url = await address() else {
            return .unreachable(["No server address is configured."])
        }
        switch await prober.ping(url, timeout: timeout) {
        case .success:
            Log.networking.info("Using server \(url.absoluteString, privacy: .public)")
            return .connected(ActiveServer(url: url))
        case .failure(let error):
            let entry = "\(url.host() ?? url.absoluteString): \(error.message)"
            Log.networking.notice("\(entry, privacy: .public)")
            return .unreachable([entry])
        }
    }

    private func publish(_ newStatus: ConnectionStatus) {
        guard newStatus != status else { return }
        status = newStatus
        for continuation in continuations.values { continuation.yield(newStatus) }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }
}

extension Duration {
    public var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
