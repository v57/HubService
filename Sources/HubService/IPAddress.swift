import Foundation

#if !canImport(Network)
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#elseif canImport(WinSDK)
import WinSDK
#endif

// Off Apple platforms Network.framework's address parsing, which Network.swift uses to validate Hub Network
// addresses: the same initializers and raw bytes, from inet_pton.
struct IPv4Address {
  let rawValue: Data
  init?(_ string: String) {
    guard let bytes = parseAddress(string, family: AF_INET, size: 4) else { return nil }
    rawValue = bytes
  }
}

struct IPv6Address {
  let rawValue: Data
  init?(_ string: String) {
    guard let bytes = parseAddress(string, family: AF_INET6, size: 16) else { return nil }
    rawValue = bytes
  }
}

private func parseAddress(_ string: String, family: Int32, size: Int) -> Data? {
  // Network accepts a zone ("fe80::1%eth0"); the bytes are the part before it.
  let host = string.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
  var buffer = [UInt8](repeating: 0, count: 16)
  let result = buffer.withUnsafeMutableBytes { inet_pton(family, host, $0.baseAddress) }
  return result == 1 ? Data(buffer.prefix(size)) : nil
}
#endif
