import Foundation
import Testing
@testable import HubService

@Suite("Device layer: Devices API")
struct DevicesAPITests {
  @Test("devices decode with services, presence and capabilities")
  func device() throws {
    let json = #"""
    [{"id":"8cef065b7af83669150b7d32704d3d3e","key":"K","name":"Mac Studio","platform":"macos","os":"27.0",
      "arch":"arm64","approved":true,"revoked":false,"online":true,"network":"offline",
      "overlay":{"address":"100.96.0.7","authority":"mac-studio-abcdefghijklmnop.v1-hub.hub.invalid"},
      "lastSeen":"2026-10-20T10:00:00.000Z","capabilities":{"cpu":{"cores":24,"model":"M3 Ultra"},
      "memory":68719476736,"disks":[{"name":"Backup Disk","free":1200000000000}],"power":"ac",
      "tools":{"xcode":"27.0","docker":true,"other":1},"custom":{"a":1}},
      "services":[{"key":"S","instance":"s3-local/Backup Disk","online":true,"paths":["s3/read"]}]},
     {"id":"x","key":"K2","approved":false,"revoked":true,"online":false,"lastSeen":"bad","services":[]}]
    """#
    let devices = try JSONDecoder().decode([Device].self, from: Data(json.utf8))
    #expect(devices.count == 2)
    let mac = devices[0]
    #expect(mac.name == "Mac Studio" && mac.approved && mac.online && mac.network == .offline)
    #expect(mac.lastSeen != nil)
    #expect(mac.overlay?.address == "100.96.0.7")
    #expect(mac.capabilities?.cpu?.cores == 24)
    #expect(mac.capabilities?.disks?.first?.free == 1_200_000_000_000)
    #expect(mac.capabilities?.tools?.docker == true)
    #expect(mac.services.first?.instance == "s3-local/Backup Disk")
    #expect(devices[1].name == "x" && devices[1].revoked && devices[1].lastSeen == nil)
    let again = try JSONDecoder().decode(Device.self, from: JSONEncoder().encode(mac))
    #expect(again == mac)
  }

  @Test("grants encode their subject and object as one-key objects")
  func grants() throws {
    let json = #"""
    [{"id":"1","subject":{"device":"d"},"object":{"prefix":"s3/"},"by":"o","at":"t"},
     {"id":"2","subject":{"everyone":true},"object":{"share":"r"}},
     {"id":"3","subject":{"group":"owners"},"object":{"path":"a/b"}},
     {"id":"4","subject":{"key":"K"},"object":{"path":"x"}}]
    """#
    let grants = try JSONDecoder().decode([Grant].self, from: Data(json.utf8))
    #expect(grants.map(\.subject) == [.device("d"), .everyone, .group("owners"), .key("K")])
    #expect(grants.map(\.object) == [.prefix("s3/"), .share("r"), .path("a/b"), .path("x")])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let body = HubDevicesAPI.AddGrant(subject: .everyone, object: .prefix("s3/"))
    #expect(String(decoding: try encoder.encode(body), as: UTF8.self) == #"{"object":{"prefix":"s3/"},"subject":{"everyone":true}}"#)
  }

  @Test("pending devices, security mode and hub info decode")
  func misc() throws {
    let pending = try JSONDecoder().decode(PendingDevice.self, from: Data(#"{"id":"i","key":"k","safetyCode":"474 971","firstSeen":"2026-10-20T10:00:00Z"}"#.utf8))
    #expect(pending.safetyCode == "474 971" && pending.firstSeenDate != nil)
    let mode = try JSONDecoder().decode(SecurityMode.self, from: Data(#"{"mode":"default-deny","requireV1":false}"#.utf8))
    #expect(mode.mode == .defaultDeny)
    let info = try JSONDecoder().decode(HubInfo.self, from: Data(#"{"key":"K","protocol":1,"pro":true,"mode":"default-allow"}"#.utf8))
    #expect(info.key == "K" && info.protocol == 1)
    let data = try JSONDecoder().decode(DeviceData.self, from: Data(#"{"battery":0.5,"charging":true,"network":"wifi","unknown":{}}"#.utf8))
    #expect(data.battery == 0.5 && data.charging == true && data.network == .wifi)
  }

  @MainActor
  @Test("service updates carry reporter and public")
  func update() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let header = ServiceHeader(path: "a/b", options: .init(isPublic: true))
    let update = HubService.Update(services: [header], apps: [], reporter: true)
    #expect(String(decoding: try encoder.encode(update), as: UTF8.self) == #"{"apps":[],"reporter":true,"services":[{"path":"a/b","public":true}]}"#)
    #expect(!HubService.Update(services: [], apps: [], reporter: true).isEmpty)
    let plain = ServiceHeader(path: "x", options: nil)
    #expect(String(decoding: try encoder.encode(plain), as: UTF8.self) == #"{"path":"x"}"#)
  }

  @Test("agent profiles name their member and device")
  func agentProfile() throws {
    let json = #"{"version":1,"key":"S","wireGuardKey":"W","overlayAddresses":["100.96.0.7"],"connectedAt":"t","member":"device:d","device":"d","deviceAuthority":"mac-x.v1-h.hub.invalid"}"#
    let profile = try JSONDecoder().decode(AgentProfile.self, from: Data(json.utf8))
    #expect(profile.member == "device:d" && profile.device == "d" && profile.deviceAuthority == "mac-x.v1-h.hub.invalid")
    let legacy = try JSONDecoder().decode(AgentProfile.self, from: Data(#"{"version":1,"key":"S","wireGuardKey":"W","overlayAddresses":[],"connectedAt":"t"}"#.utf8))
    #expect(legacy.member == nil && legacy.device == nil)
  }

  @Test("ssh host keys are signed by the device")
  func ssh() throws {
    let device = DeviceKey(KeyChain(.none))
    let ssh = Capabilities.SSH(port: 22, hostKey: "ssh-ed25519 AAAA host", device: device)
    #expect(!ssh.hostKeySignature.isEmpty)
  }
}
