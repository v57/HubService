//
//  File.swift
//  HubService
//
//  Created by Dmitry Kozlov on 30/4/25.
//

import Foundation
import CryptoKit

public struct KeyChain: Sendable {
  private static let fileURL: URL = FileManager.default
    .urls(for: .documentDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("ed25519.key")
  
  private let privateKey: Curve25519.Signing.PrivateKey
  public init(keyChain: String? = nil) {
    if let keyChain,
       let keyData: Data = KeyChain.fromKeychain(tag: keyChain),
       let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) {
      self.privateKey = key
    } else if let keyData = KeyChain.fromFile(),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) {
      self.privateKey = key
    } else {
      let key = Curve25519.Signing.PrivateKey()
      let raw = key.rawRepresentation
      if let keyChain, KeyChain.storeInKeychain(data: raw, tag: keyChain) {
        self.privateKey = key
      } else {
        KeyChain.storeInFile(data: raw)
        self.privateKey = key
      }
    }
  }
  func sign(text: String) -> String {
    let data = Data(text.utf8)
    let signature = try! privateKey.signature(for: data)
    return signature.base64EncodedString()
  }

  public func publicKey() -> String {
    // ed25519 prefix
    let prefix = Data([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00])
    return (prefix + privateKey.publicKey.rawRepresentation).base64EncodedString()
  }

  // MARK: - Storage Helpers
  public static func fromKeychain<T>(tag: String) -> T? {
    let query = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: tag,
      kSecReturnData: kCFBooleanTrue!,
      kSecMatchLimit: kSecMatchLimitOne
    ] as [CFString: Any] as CFDictionary
    var value: AnyObject?
    let status = SecItemCopyMatching(query, &value)
    guard status == errSecSuccess else { return nil }
    return value as? T
  }

  private static func fromFile() -> Data? {
    try? Data(contentsOf: fileURL)
  }

  public static func storeInKeychain<T>(data: T, tag: String) -> Bool {
    let query = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: tag,
      kSecValueData: data
    ] as [CFString: Any] as CFDictionary
    SecItemDelete(query)
    return SecItemAdd(query, nil) == errSecSuccess
  }

  private static func storeInFile(data: Data) {
    do {
      try data.write(to: fileURL, options: .atomic)
    } catch {
      print("Failed to write Ed25519 key to file: \(error)")
    }
  }
}
