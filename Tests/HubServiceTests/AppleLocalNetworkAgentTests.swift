import Testing
@testable import HubService

#if canImport(Network)
@Suite("Apple local-agent IPC")
struct AppleLocalNetworkAgentTests {
  @Test("the socket is the environment's, the system agent's, then the Hub app's in the home folder")
  func socketPath() {
    #expect(AppleLocalNetworkAgent.socketPath(environment: ["HUB_NET_AGENT_SOCKET": "/tmp/a.sock", "HOME": "/Users/me"], exists: { _ in true }) == "/tmp/a.sock")
    #expect(AppleLocalNetworkAgent.socketPath(environment: ["HOME": "/Users/me"], exists: { _ in true }) == "/var/run/hub-net/agent.sock")
    #expect(AppleLocalNetworkAgent.socketPath(environment: ["HOME": "/Users/me"], exists: { _ in false }) == "/Users/me/.hub-net/agent.sock")
  }

  @Test("unavailable socket returns a diagnosable transport error")
  func unavailableAgent() async {
    let agent = AppleLocalNetworkAgent(
      socketPath: "/tmp/hub-net-agent-that-does-not-exist.sock",
      timeout: 0.25
    )
    let share = NetworkShare(
      name: "s3",
      protocol: .tcp,
      target: LocalTarget(port: 9000)
    )

    do {
      _ = try await agent.attestation(
        for: share,
        serviceKey: "service-key"
      ) { _ in "signature" }
      Issue.record("Expected unavailable local agent to fail")
    } catch let error as HubNetworkError {
      switch error {
      case .agentTransport, .agentTimeout:
        break
      default:
        Issue.record("Unexpected local-agent error: \(error)")
      }
    } catch {
      Issue.record("Unexpected untyped error: \(error)")
    }
  }
}
#endif
