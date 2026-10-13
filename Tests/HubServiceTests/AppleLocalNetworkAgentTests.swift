import Testing
@testable import HubService

#if canImport(Network)
@Suite("Apple local-agent IPC")
struct AppleLocalNetworkAgentTests {
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
