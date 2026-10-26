import Foundation
import Testing
@testable import HubService

@Suite("App interface")
struct AppInterfaceTests {
  func decode(_ json: String) throws -> AppInterface {
    try JSONDecoder().decode(AppInterface.self, from: Data(json.utf8))
  }

  @Test("decodes every element of the shared fixture without warnings")
  func fixture() throws {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/app-interface", withExtension: "json"))
    let app = try JSONDecoder().decode(AppInterface.self, from: Data(contentsOf: url))
    #expect(app.warnings == 0)
    let body = try #require(app.body)
    #expect(body.count == 25)
    let types = body.map(\.element.type)
    for type in [ElementType.markdown, .image, .badge, .divider, .link, .stat, .gauge, .chart, .table, .grid, .section, .tabs, .sheet] {
      #expect(types.contains(type), "missing \(type)")
    }
    let header = try #require(app.header)
    #expect(header.icon == "chart.bar")
    #expect(header.widget?.sizes == [.x11, .x22])
    #expect(app.widget?[.x11]?.count == 1)
    #expect(app.widget?[.x22]?.first?.element.type == .stat)
    #expect(app.data?["usersHistory"]?.array?.count == 4)
  }

  @Test("reads element options")
  func options() throws {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/app-interface", withExtension: "json"))
    let body = try #require(try JSONDecoder().decode(AppInterface.self, from: Data(contentsOf: url)).body)
    guard case .text(let text) = body[1] else { Issue.record("not text"); return }
    #expect(text.style == .title && text.color == "blue" && text.secondary)
    guard case .stat(let stat) = body[8] else { Issue.record("not stat"); return }
    #expect(stat.value == .string("$users") && stat.delta == .string("$usersDelta"))
    #expect(stat.deltaFormat == .percent && stat.sparkline == .key("$usersHistory"))
    guard case .gauge(let gauge) = body[9] else { Issue.record("not gauge"); return }
    #expect(gauge.max == 100 && gauge.style == .semicircle && gauge.thresholds.first?.value == 80)
    guard case .chart(let line) = body[10] else { Issue.record("not chart"); return }
    #expect(line.kind == .line && line.series.count == 2 && line.x == .time && line.legend == true)
    #expect(line.series[0].data == .key("$in"))
    guard case .points(let points) = line.series[1].data else { Issue.record("not points"); return }
    #expect(points.count == 2)
    guard case .table(let table) = body[14] else { Issue.record("not table"); return }
    #expect(table.columns.map(\.key) == ["name", "status"] && table.columns[1].style == .badge)
    guard case .tabs(let tabs) = body[17] else { Issue.record("not tabs"); return }
    #expect(tabs.tabs.map(\.title) == ["Day", "Week"] && tabs.selected == "range")
    guard case .button(let button) = body[19] else { Issue.record("not button"); return }
    #expect(button.style == .destructive && button.confirm?.destructive == true && button.icon == "trash")
    guard case .button(let plain) = body[20] else { Issue.record("not button"); return }
    #expect(plain.action.path == "demo/refresh")
  }

  @Test("skips unknown elements and counts them as warnings")
  func unknownElements() throws {
    let app = try decode("""
    {"body": ["a", {"type": "hologram", "value": 1}, {"type": "grid", "content": ["b", {"type": "future"}]},
      {"type": "chart", "kind": "radar", "series": [{"name": "x", "data": [1, 2]}]},
      {"type": "gauge", "value": 1, "style": "dial"}]}
    """)
    let body = try #require(app.body)
    #expect(body.count == 4)
    guard case .grid(let grid) = body[1] else { Issue.record("not grid"); return }
    #expect(grid.content.count == 1)
    guard case .chart(let chart) = body[2] else { Issue.record("not chart"); return }
    #expect(chart.kind == .line)
    guard case .gauge(let gauge) = body[3] else { Issue.record("not gauge"); return }
    #expect(gauge.style == .ring)
    #expect(app.warnings == 4)
  }

  @Test("older apps still decode")
  func older() throws {
    let app = try decode("""
    {"header": {"type": "app", "name": "Weather", "path": "weather/ui"},
     "body": [{"type": "button", "title": "Load", "action": {"path": "weather/ui/load"}}, {"type": "progress", "value": "humidity"}],
     "data": {"humidity": 40}}
    """)
    #expect(app.warnings == 0)
    #expect(app.body?.count == 2)
    #expect(app.header?.widget == nil && app.widget == nil)
  }

  @Test("app headers read new kinds and ignore what they don't know")
  func headers() throws {
    let headers = try JSONDecoder().decode([AppHeader].self, from: Data("""
    [{"type": "app", "name": "A", "path": "a"},
     {"type": "app", "name": "W", "path": "w", "widget": {"sizes": ["2x1", "3x3", "1x1"]}, "services": 2},
     {"type": "app", "name": "Web", "path": "web", "icon": "globe", "web": {"url": "http://{hubHost}:8080/", "token": true}},
     {"type": "kiosk", "name": "K", "path": "k", "widget": {"sizes": ["9x9"]}, "web": 3}]
    """.utf8))
    #expect(headers.count == 4)
    #expect(headers[1].widget?.sizes == [.x21, .x11] && headers[1].widget?.defaultSize == .x21)
    #expect(headers[2].web?.token == true && headers[2].icon == "globe")
    #expect(headers[2].web?.url(hubHost: "10.0.0.2")?.absoluteString == "http://10.0.0.2:8080/")
    // The host comes from the address the client is connected on, such as a Hub Network one
    #expect(headers[2].web?.url(hub: URL(string: "ws://100.96.0.2:1997")!)?.absoluteString == "http://100.96.0.2:8080/")
    #expect(headers[2].web?.url(hub: URL(string: "ws://[fd00::2]:1997")!)?.absoluteString == "http://[fd00::2]:8080/")
    #expect(headers[3].type == .app && headers[3].widget?.sizes == [.x11] && headers[3].web == nil)
  }

  @Test("widget sizes round trip")
  func widgetEncoding() throws {
    let app = App(header: AppHeader(type: .app, name: "Users", path: "users")) {
      Element.Text(value: "Full")
    }.widget(sizes: [.x21], body: [.stat(.init(title: "Users", value: "$users"))], bodies: [.x21: [.badge(.init(value: "ok"))], .x22: []])
    #expect(app.header.widget?.sizes == [.x21])
    var interface = AppInterface(header: app.header, body: app.body, top: nil, bottom: nil, data: nil)
    interface.widget = app.widget
    let decoded = try JSONDecoder().decode(AppInterface.self, from: JSONEncoder().encode(interface))
    #expect(decoded.warnings == 0)
    #expect(decoded.widget?[.x21]?.first?.element.type == .badge)
    #expect(decoded.widget?[.x11]?.first?.element.type == .stat)
    #expect(decoded.widget?.sizes[.x22] == nil)
  }
}
