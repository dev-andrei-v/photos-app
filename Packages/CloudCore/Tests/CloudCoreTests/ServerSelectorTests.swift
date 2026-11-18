import Core
import Foundation
import Testing
import CloudCore

/// Answers pings from a fixed table; records which servers were tried.
final class FakeProber: ServerProber, @unchecked Sendable {
    private let lock = NSLock()
    private let reachable: Set<String>
    private let delay: Duration
    private(set) var attempts: [(host: String, timeout: Duration)] = []

    init(reachable: Set<String>, delay: Duration = .zero) {
        self.reachable = reachable
        self.delay = delay
    }

    func ping(_ server: URL, timeout: Duration) async -> Result<Void, CloudError> {
        let host = server.host() ?? ""
        lock.withLock { attempts.append((host, timeout)) }
        if delay > .zero { try? await Task.sleep(for: delay) }
        return reachable.contains(host)
            ? .success(())
            : .failure(CloudError(kind: .transport, message: "the server did not answer in time."))
    }

    var hostsTried: [String] { lock.withLock { attempts.map(\.host) } }
}

private let address = URL(string: "https://photos.example.com")!

@Suite struct ServerSelectorTests {
    @Test func connectsWhenTheServerAnswers() async {
        let prober = FakeProber(reachable: ["photos.example.com"])
        let selector = ServerSelector(prober: prober) { address }
        #expect(await selector.resolve() == .connected(ActiveServer(url: address)))
        #expect(prober.hostsTried == ["photos.example.com"])
    }

    @Test func usesTheGivenTimeout() async {
        let prober = FakeProber(reachable: [])
        let selector = ServerSelector(prober: prober, timeout: .seconds(3)) { address }
        _ = await selector.resolve()
        #expect(prober.attempts.map(\.timeout) == [.seconds(3)])
    }

    @Test func reportsTheFailureReadably() async {
        let selector = ServerSelector(prober: FakeProber(reachable: [])) { address }
        #expect(await selector.resolve() == .unreachable(["photos.example.com: the server did not answer in time."]))
    }

    @Test func noAddressConfigured() async {
        let selector = ServerSelector(prober: FakeProber(reachable: [])) { nil }
        #expect(await selector.resolve() == .unreachable(["No server address is configured."]))
    }

    @Test func concurrentResolvesShareOneProbe() async {
        let prober = FakeProber(reachable: ["photos.example.com"], delay: .milliseconds(50))
        let selector = ServerSelector(prober: prober) { address }
        async let first = selector.resolve()
        async let second = selector.resolve()
        let results = await [first, second]
        #expect(results[0] == results[1])
        #expect(prober.hostsTried == ["photos.example.com"])
    }

    @Test func recoversWhenTheServerComesBack() async {
        final class Toggle: @unchecked Sendable { var isUp = false }
        let toggle = Toggle()
        struct NetworkDependentProber: ServerProber {
            let toggle: Toggle
            func ping(_ server: URL, timeout: Duration) async -> Result<Void, CloudError> {
                toggle.isUp ? .success(()) : .failure(CloudError(kind: .transport, message: "unreachable"))
            }
        }
        let selector = ServerSelector(prober: NetworkDependentProber(toggle: toggle)) { address }
        #expect(await selector.resolve().activeServer == nil)
        toggle.isUp = true
        #expect(await selector.resolve().activeServer?.url == address)
    }

    @Test func publishesStatusUpdates() async {
        let selector = ServerSelector(prober: FakeProber(reachable: ["photos.example.com"])) { address }
        let updates = await selector.updates()
        _ = await selector.resolve()
        var seen: [ConnectionStatus] = []
        for await status in updates {
            seen.append(status)
            if case .connected = status { break }
        }
        #expect(seen.last?.activeServer?.url == address)
    }

    @Test(arguments: [
        ("https://photos.example.com", true),
        ("http://192.168.1.10:2283", true),
        ("http://my-server.tail1234.ts.net:2283", false),
        ("http://100.64.0.10:2283", false),
        ("http://100.128.0.10:2283", true),
    ])
    func knowsWhichAddressesOtherDevicesCanOpen(address: String, expected: Bool) {
        #expect(ActiveServer(url: URL(string: address)!).isReachableByOtherDevices == expected)
    }
}
