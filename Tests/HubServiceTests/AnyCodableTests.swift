import Foundation
import Testing
@testable import HubService

@Suite("AnyCodable")
struct AnyCodableTests {
  func roundTrip(_ json: String) throws -> String {
    let value = try JSONDecoder().decode(AnyCodable.self, from: Data(json.utf8))
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }

  @Test("booleans stay booleans, not numbers or empty objects")
  func booleans() throws {
    #expect(try roundTrip(#"{"banned":false,"owner":true,"count":1}"#) == #"{"banned":false,"count":1,"owner":true}"#)
    let value = try JSONDecoder().decode(AnyCodable.self, from: Data(#"[true, 0, "true"]"#.utf8))
    #expect(value.array?.map(\.bool) == [true, false, true])
  }

  @Test("null stays null")
  func null() throws {
    #expect(try roundTrip(#"{"a":null,"b":[null]}"#) == #"{"a":null,"b":[null]}"#)
  }
}
