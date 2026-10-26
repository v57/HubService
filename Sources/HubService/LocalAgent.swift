import Foundation

#if canImport(Network)
import Network

public actor AppleLocalNetworkAgent {
  /// The system agent's socket
  public static let systemSocketPath = "/var/run/hub-net/agent.sock"
  /// `HUB_NET_AGENT_SOCKET`, the system agent's socket, or else the Hub app's, which runs as the user and can't create
  /// one under `/var/run` (`~/.hub-net/agent.sock`)
  public static var defaultSocketPath: String {
    socketPath(environment: ProcessInfo.processInfo.environment, exists: FileManager.default.fileExists(atPath:))
  }
  static func socketPath(environment: [String: String], exists: (String) -> Bool) -> String {
    if let path = environment["HUB_NET_AGENT_SOCKET"], !path.isEmpty { return path }
    guard !exists(systemSocketPath), let home = environment["HOME"] else { return systemSocketPath }
    return "\(home)/.hub-net/agent.sock"
  }
  private static let maximumResponseLength = 1_048_576

  private let socketPath: String
  private let timeout: TimeInterval

  public init(
    socketPath: String = AppleLocalNetworkAgent.defaultSocketPath,
    timeout: TimeInterval = 5
  ) {
    self.socketPath = socketPath
    self.timeout = timeout
  }

  public func attestation(for share: NetworkShare, serviceKey: String, sign: @escaping @Sendable (String) async throws -> String) async throws -> AgentAttestation {
    let challenge: ChallengeResponse = try await post(
      path: "/challenge",
      body: ChallengeRequest(
        serviceKey: serviceKey,
        shareName: share.name,
        protocol: share.protocol,
        target: share.target
      )
    )
    let signature = try await sign(challenge.nonce)
    return try await post(
      path: "/attest",
      body: AttestationRequest(
        serviceKey: serviceKey,
        shareName: share.name,
        protocol: share.protocol,
        target: share.target,
        signature: signature
      )
    )
  }

  private func post<Body: Encodable, Response: Decodable>(
    path: String,
    body: Body
  ) async throws -> Response {
    let bodyData = try JSONEncoder().encode(body)
    var request = Data(
      """
      POST \(path) HTTP/1.1\r
      Host: localhost\r
      Content-Type: application/json\r
      Content-Length: \(bodyData.count)\r
      Connection: close\r
      \r
      """.utf8
    )
    request.append(bodyData)

    let response = try await exchange(request)
    guard let separator = response.range(of: Data("\r\n\r\n".utf8)) else {
      throw HubNetworkError.invalidAgentResponse
    }
    let headerData = response[..<separator.lowerBound]
    let responseBody = response[separator.upperBound...]
    guard let headers = String(data: headerData, encoding: .utf8),
          let statusLine = headers.split(separator: "\r\n").first,
          let status = Int(statusLine.split(separator: " ").dropFirst().first ?? "") else {
      throw HubNetworkError.invalidAgentResponse
    }
    guard (200..<300).contains(status) else {
      let message = String(data: responseBody, encoding: .utf8) ?? "Local agent rejected request"
      throw HubNetworkError.agentRejected(status: status, message: message)
    }
    do {
      return try JSONDecoder().decode(Response.self, from: responseBody)
    } catch {
      throw HubNetworkError.invalidAgentResponse
    }
  }

  private func exchange(_ request: Data) async throws -> Data {
    let connection = NWConnection(
      to: .unix(path: socketPath),
      using: .tcp
    )
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let state = ConnectionState(continuation: continuation)
        connection.stateUpdateHandler = { newState in
          switch newState {
          case .ready:
            connection.send(content: request, completion: .contentProcessed { error in
              if let error {
                state.fail(HubNetworkError.agentTransport(error.localizedDescription))
                connection.cancel()
              } else {
                Self.receive(connection: connection, state: state)
              }
            })
          case .failed(let error):
            state.fail(HubNetworkError.agentTransport(error.localizedDescription))
          case .cancelled:
            state.fail(CancellationError())
          default:
            break
          }
        }
        connection.start(queue: .global(qos: .userInitiated))
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
          state.fail(HubNetworkError.agentTimeout)
          connection.cancel()
        }
      }
    } onCancel: {
      connection.cancel()
    }
  }

  nonisolated private static func receive(
    connection: NWConnection,
    state: ConnectionState
  ) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) {
      data, _, isComplete, error in
      if let data {
        guard state.append(data, maximumLength: maximumResponseLength) else {
          connection.cancel()
          return
        }
      }
      if let error {
        state.fail(HubNetworkError.agentTransport(error.localizedDescription))
        connection.cancel()
      } else if isComplete {
        state.succeed()
        connection.cancel()
      } else {
        receive(connection: connection, state: state)
      }
    }
  }
}

private struct ChallengeRequest: Codable {
  let serviceKey: String
  let shareName: String
  let `protocol`: NetworkProtocol
  let target: LocalTarget
}

private struct ChallengeResponse: Codable {
  let nonce: String
}

private struct AttestationRequest: Codable {
  let serviceKey: String
  let shareName: String
  let `protocol`: NetworkProtocol
  let target: LocalTarget
  let signature: String
}

private final class ConnectionState: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()
  private var continuation: CheckedContinuation<Data, Error>?

  init(continuation: CheckedContinuation<Data, Error>) {
    self.continuation = continuation
  }

  func append(_ newData: Data, maximumLength: Int) -> Bool {
    lock.lock()
    guard data.count <= maximumLength - newData.count else {
      lock.unlock()
      fail(HubNetworkError.invalidAgentResponse)
      return false
    }
    data.append(newData)
    lock.unlock()
    return true
  }

  func succeed() {
    finish(.success(data))
  }

  func fail(_ error: Error) {
    finish(.failure(error))
  }

  private func finish(_ result: Result<Data, Error>) {
    lock.lock()
    guard let continuation else {
      lock.unlock()
      return
    }
    self.continuation = nil
    lock.unlock()
    continuation.resume(with: result)
  }
}

@MainActor
public extension HubNetworkService {
  func useAppleLocalAgent(
    socketPath: String = AppleLocalNetworkAgent.defaultSocketPath,
    timeout: TimeInterval = 5
  ) {
    let agent = AppleLocalNetworkAgent(socketPath: socketPath, timeout: timeout)
    setAttestationProvider { share, serviceKey, sign in
      try await agent.attestation(for: share, serviceKey: serviceKey, sign: sign)
    }
  }
}
#endif
