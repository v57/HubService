import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Testing
@testable import HubService

@Suite("Device layer: certificates")
struct CertificateTests {
  @Test("device id and safety code")
  func deviceId() throws {
    let vectors = try Vectors.load()
    let vector = vectors.keys["device"]!
    let device = DeviceKey(try key(vector))
    #expect(device.id == vector.deviceId)
    #expect(device.safetyCode == vector.safetyCode)
    #expect(DeviceKey.id(publicKey: vector.publicKey) == vector.deviceId)
  }

  @Test("certificates match the vectors")
  func certificates() throws {
    let vectors = try Vectors.load()
    let device = DeviceKey(try key(vectors.keys["device"]!))
    let service = vectors.keys["service"]!.publicKey
    let certificate = device.certificate(
      service: service, instance: "s3-local/Backup Disk", deviceName: "Mac Studio", platform: "macos",
      issuedAt: 1792500000
    )
    #expect(ServiceCertificate.json(certificate.fields) == vectors.certificate.json)
    #expect(certificate.payload == vectors.certificate.payload)
    #expect(verify(certificate.signature, certificate.payload, device.publicKey))
    #expect(verify(vectors.certificate.signature, vectors.certificate.payload, device.publicKey))
    #expect(vectors.certificate.header == "\(vectors.certificate.payload).\(vectors.certificate.signature)")

    let child = device.certificate(
      service: service, instance: "builder", deviceName: "builder", platform: "linux", parent: "Mac Studio",
      issuedAt: 1792500000
    )
    #expect(ServiceCertificate.json(child.fields) == vectors.childCertificate.json)
    #expect(child.payload == vectors.childCertificate.payload)
    #expect(verify(child.signature, child.payload, device.publicKey))
    #expect(verify(vectors.childCertificate.signature, vectors.childCertificate.payload, device.publicKey))
  }

  @Test("lifetime is capped at 7 days and renewal starts with a day left")
  func lifetime() throws {
    let device = DeviceKey(KeyChain(.none))
    let certificate = device.certificate(service: "s", instance: "i", issuedAt: 1000, lifetime: 10 * 86_400)
    #expect(certificate.fields.exp - certificate.fields.iat == 604_800)
    #expect(!certificate.needsRenewal(now: 1000 + 5 * 86_400))
    #expect(certificate.needsRenewal(now: 1000 + 6 * 86_400 + 1))
  }

  @MainActor
  @Test("a changed instance name gets a new certificate")
  func instanceChange() throws {
    var name = "a"
    let issuer = CertificateIssuer(device: DeviceIdentity(key: DeviceKey(KeyChain(.none))), service: "s") { name }
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let first = issuer.header(now: start)
    name = "b"
    #expect(issuer.header(now: start) != first)
  }

  @MainActor
  @Test("the issuer reuses a certificate until it needs renewal")
  func issuer() throws {
    let issuer = CertificateIssuer(device: DeviceIdentity(key: DeviceKey(KeyChain(.none))), service: "s", instance: "i")
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let first = issuer.header(now: start)
    #expect(issuer.header(now: start.addingTimeInterval(3600)) == first)
    #expect(issuer.header(now: start.addingTimeInterval(6.5 * 86_400)) != first)
  }

  @Test("device key file is created once with 0600 and read back")
  func deviceFile() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("hub/device.key")
    let created = try DeviceKey.file(url)
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let directoryAttributes = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
    #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    let loaded = try DeviceKey.file(url)
    #expect(loaded.publicKey == created.publicKey)
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(try KeyChain(keyFile: text).publicKey() == created.publicKey)
  }

  @Test("long names are cut to their byte limits")
  func names() {
    let identity = DeviceIdentity(key: DeviceKey(KeyChain(.none)), name: String(repeating: "é", count: 40))
    #expect(identity.name!.utf8.count == 64)
  }
}
