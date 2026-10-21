//
//  Dashboard.swift
//  HubUI
//
//  Views for the app elements of protocol 2 (Docs/Apps/ui.md): stats, gauges, charts, tables and layouts.
//  They live outside `extension Element` so SwiftUI names aren't shadowed by the element models.
//

#if !canImport(SwiftCrossUI)
import SwiftUI
import HubService
#if canImport(Charts)
import Charts
#endif

// MARK: Values

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension Element.AppState {
  /// Data at `key` or `$key`, from the list row first
  func any(_ key: String) -> AnyCodable? {
    let key = key.hasPrefix("$") ? String(key.dropFirst()) : key
    return nested?.data?[key] ?? app.data[key]
  }
  func resolve(_ value: Element.Value) -> AnyCodable? {
    switch value {
    case .number(let number): .double(number)
    case .string(let string): string.hasPrefix("$") ? any(string) : .string(string)
    }
  }
  func number(_ value: Element.Value?) -> Double? {
    guard let value else { return nil }
    return resolve(value)?.double
  }
  /// Text with numbers formatted for people
  func text(_ value: Element.Value) -> String? {
    guard let value = resolve(value) else { return nil }
    return value.displayText
  }
  /// `text` for string fields that may be `$key`
  func text(_ string: String?) -> String? {
    guard let string else { return nil }
    return text(.string(string))
  }
  func points(_ points: Element.Points) -> [AnyCodable] {
    switch points {
    case .key(let key): any(key)?.array ?? []
    case .points(let points): points
    }
  }
  func color(_ name: String?) -> Color? {
    guard let name else { return nil }
    let resolved = name.hasPrefix("$") ? any(name)?.string : name
    return resolved.flatMap(Color.init(hubName:))
  }
}

extension AnyCodable {
  var displayText: String? {
    switch self {
    case .int(let int): int.formatted()
    case .double(let double): double.hubFormatted()
    case .string(let string): string
    case .date(let date): date.formatted(date: .abbreviated, time: .shortened)
    default: nil
    }
  }
}

extension Double {
  /// 12, 12.5, 1,234, 12.3K, 4.5M
  func hubFormatted() -> String {
    if abs(self) >= 100_000 {
      return formatted(.number.notation(.compactName).precision(.significantDigits(3)))
    }
    return formatted(.number.precision(.fractionLength(0...(abs(self) < 10 ? 2 : 1))))
  }
}

extension Color {
  /// Named system colors and `#rrggbb`
  init?(hubName name: String) {
    switch name.lowercased() {
    case "red": self = .red
    case "orange": self = .orange
    case "yellow": self = .yellow
    case "green": self = .green
    case "mint": self = .mint
    case "teal": self = .teal
    case "cyan": self = .cyan
    case "blue": self = .blue
    case "indigo": self = .indigo
    case "purple": self = .purple
    case "pink": self = .pink
    case "brown": self = .brown
    case "gray", "grey": self = .gray
    case "primary": self = .primary
    case "secondary": self = .secondary
    case "accent": self = .accentColor
    default:
      var hex = name
      guard hex.hasPrefix("#") else { return nil }
      hex.removeFirst()
      guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
      self = Color(red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255, blue: Double(value & 0xff) / 255)
    }
  }
  /// Status words read as colors when a badge has none
  static func status(_ text: String) -> Color {
    switch text.lowercased() {
    case "ok", "up", "online", "healthy", "active", "running", "success", "done", "paid", "live": .green
    case "warning", "degraded", "pending", "slow", "queued", "review": .orange
    case "down", "offline", "error", "failed", "critical", "blocked", "banned": .red
    default: .secondary
    }
  }
}

/// Set on widget content, so elements fill the tile instead of taking their page sizes
struct HubWidgetSizeKey: EnvironmentKey {
  static let defaultValue: WidgetSize? = nil
}
extension EnvironmentValues {
  var hubWidgetSize: WidgetSize? {
    get { self[HubWidgetSizeKey.self] }
    set { self[HubWidgetSizeKey.self] = newValue }
  }
}

// MARK: Text

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension Element.TextStyle {
  var font: Font {
    switch self {
    case .largeTitle: .largeTitle.bold()
    case .title: .title2.bold()
    case .headline: .headline
    case .body: .body
    case .callout: .callout
    case .caption: .caption
    case .footnote: .footnote
    case .monospaced: .body.monospaced()
    }
  }
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
struct HubMarkdownView: View {
  let value: Element.Markdown
  let state = Element.AppState()
  var body: some View {
    if let text = state.text(value.value) {
      let attributed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
      Text(attributed).textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
struct HubImageView: View {
  let value: Element.Image
  let state = Element.AppState()
  var body: some View {
    let color = state.color(value.color)
    Group {
      if let symbol = state.text(value.symbol) {
        Image(systemName: symbol)
          .resizable().aspectRatio(contentMode: .fit)
          .foregroundStyle(color ?? .primary)
          .frame(width: value.width.map { CGFloat($0) } ?? (value.height == nil ? 24 : nil), height: value.height.map { CGFloat($0) })
      } else if let url = state.text(value.url).flatMap(URL.init(string:)), url.scheme == "https" || url.scheme == "http" {
        AsyncImage(url: url) { image in
          image.resizable().aspectRatio(contentMode: value.mode == .fill ? .fill : .fit)
        } placeholder: {
          Rectangle().fill(.quaternary)
        }.frame(width: value.width.map { CGFloat($0) }, height: value.height.map { CGFloat($0) })
          .clipShape(RoundedRectangle(cornerRadius: value.cornerRadius ?? 0))
      }
    }
  }
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
struct HubBadgeView: View {
  let value: Element.Badge
  let state = Element.AppState()
  var body: some View {
    if let text = state.text(value.value) {
      HubBadge(text: text, color: state.color(value.color) ?? .status(text))
    }
  }
}

struct HubBadge: View {
  let text: String
  let color: Color
  var body: some View {
    Text(text).font(.caption.weight(.semibold)).lineLimit(1)
      .padding(.horizontal, 7).padding(.vertical, 2)
      .foregroundStyle(color)
      .background(color.opacity(0.15), in: Capsule())
  }
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
struct HubLinkView: View {
  let value: Element.Link
  let state = Element.AppState()
  var body: some View {
    if let title = state.text(value.title), let url = state.text(value.url).flatMap(URL.init(string:)),
       ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
      Link(destination: url) {
        if let icon = value.icon {
          Label(title, systemImage: icon)
        } else {
          Text(title)
        }
      }
    }
  }
}

// MARK: Stat

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
struct HubStatView: View {
  let value: Element.Stat
  let state = Element.AppState()
  @Environment(\.hubWidgetSize) private var widgetSize
  var deltaText: (String, Color)? {
    guard let delta = state.number(value.delta) else {
      // A text delta shows as it is
      if let delta = value.delta, let text = state.text(delta) { return (text, .secondary) }
      return nil
    }
    let text = value.deltaFormat == .percent
      ? delta.formatted(.percent.precision(.fractionLength(0...1)).sign(strategy: .always()))
      : delta.formatted(.number.precision(.fractionLength(0...2)).sign(strategy: .always()))
    let good = value.positive == .down ? delta < 0 : delta > 0
    return (text, delta == 0 ? .secondary : good ? .green : .red)
  }
  var body: some View {
    let color = state.color(value.color)
    let sparkline = value.sparkline.map { state.points($0).compactMap(\.double) } ?? []
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 4) {
        if let icon = value.icon {
          Image(systemName: icon).foregroundStyle(color ?? .secondary)
        }
        Text(state.text(value.title) ?? value.title).lineLimit(1)
      }.font(.subheadline).foregroundStyle(.secondary)
      HStack(alignment: .firstTextBaseline, spacing: 3) {
        Text(state.text(value.value) ?? "–")
          .font(.system(size: widgetSize == .x11 ? 26 : 30, weight: .semibold, design: .rounded))
          .minimumScaleFactor(0.5).lineLimit(1)
          .contentTransition(.numericText())
          .animation(.smooth, value: state.text(value.value))
        if let unit = value.unit {
          Text(unit).font(.headline).foregroundStyle(.secondary)
        }
      }
      if let (delta, deltaColor) = deltaText {
        Text(delta).font(.caption.weight(.semibold)).foregroundStyle(deltaColor)
          .contentTransition(.numericText())
      }
      if sparkline.count > 1 {
        HubSparkline(values: sparkline, color: color ?? .accentColor)
          .frame(height: widgetSize == nil ? 32 : nil)
          .frame(minHeight: 16, maxHeight: widgetSize == nil ? 32 : .infinity)
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
struct HubSparkline: View {
  let values: [Double]
  let color: Color
  var body: some View {
#if canImport(Charts)
    let low = values.min() ?? 0
    let high = values.max() ?? 1
    Chart(Array(values.enumerated()), id: \.offset) { point in
      AreaMark(x: .value("i", point.offset), yStart: .value("low", low), yEnd: .value("v", point.element))
        .foregroundStyle(LinearGradient(colors: [color.opacity(0.25), color.opacity(0)], startPoint: .top, endPoint: .bottom))
        .interpolationMethod(.catmullRom)
      LineMark(x: .value("i", point.offset), y: .value("v", point.element))
        .foregroundStyle(color)
        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
        .interpolationMethod(.catmullRom)
    }.chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
      .chartYScale(domain: low...(high > low ? high : low + 1))
      .animation(.smooth, value: values)
#endif
  }
}

// MARK: Gauge

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
struct HubGaugeView: View {
  let value: Element.Gauge
  let state = Element.AppState()
  @Environment(\.hubWidgetSize) private var widgetSize
  var body: some View {
    let current = state.number(value.value) ?? value.min
    let high = Swift.max(value.max, value.min + .ulpOfOne)
    let fraction = Swift.min(Swift.max((current - value.min) / (high - value.min), 0), 1)
    let threshold = value.thresholds.sorted { $0.value < $1.value }.last { current >= $0.value }
    let color = state.color(threshold?.color) ?? state.color(value.color) ?? .accentColor
    let label = state.text(value.label) ?? state.text(value.value) ?? ""
    let title = state.text(value.title)
    switch value.style {
    case .bar:
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          if let title { Text(title).foregroundStyle(.secondary) }
          Spacer(minLength: 0)
          Text(label).monospacedDigit().contentTransition(.numericText())
        }.font(.subheadline)
        GeometryReader { view in
          Capsule().fill(color.opacity(0.15)).overlay(alignment: .leading) {
            Capsule().fill(color.gradient).frame(width: Swift.max(view.size.width * fraction, 6))
          }
        }.frame(height: 8)
      }.frame(maxWidth: .infinity).animation(.smooth, value: fraction)
    case .ring:
      VStack(spacing: 4) {
        ZStack {
          arcs(arc: 1, fraction: fraction, color: color).rotationEffect(.degrees(-90))
          centerLabel(label)
        }.aspectRatio(1, contentMode: .fit)
          .frame(maxWidth: widgetSize == nil ? 110 : .infinity)
        if let title {
          Text(title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
      }.animation(.smooth, value: fraction)
    case .semicircle:
      VStack(spacing: 4) {
        Color.clear.aspectRatio(2, contentMode: .fit)
          .overlay(alignment: .top) {
            GeometryReader { view in
              arcs(arc: 0.5, fraction: fraction, color: color).rotationEffect(.degrees(180))
                .frame(width: view.size.width, height: view.size.width)
            }
          }.overlay(alignment: .bottom) {
            centerLabel(label)
          }.frame(maxWidth: widgetSize == nil ? 160 : .infinity)
        if let title {
          Text(title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
      }.animation(.smooth, value: fraction)
    }
  }
  func arcs(arc: Double, fraction: Double, color: Color) -> some View {
    ZStack {
      Circle().trim(from: 0, to: arc)
        .stroke(color.opacity(0.15), style: StrokeStyle(lineWidth: 8, lineCap: .round))
      Circle().trim(from: 0, to: arc * fraction)
        .stroke(color.gradient, style: StrokeStyle(lineWidth: 8, lineCap: .round))
    }.padding(4)
  }
  func centerLabel(_ label: String) -> some View {
    Text(label).font(.system(.title3, design: .rounded).weight(.semibold))
      .minimumScaleFactor(0.5).lineLimit(1).padding(14)
      .monospacedDigit().contentTransition(.numericText())
  }
}

// MARK: Chart

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
struct HubChartView: View {
  let value: Element.Chart
  let state = Element.AppState()
  @Environment(\.hubWidgetSize) private var widgetSize
  struct Point: Identifiable {
    let id: Int
    let series: String
    let x: X
    let y: Double
  }
  enum X {
    case number(Double), category(String), time(Date)
    var number: Double { if case .number(let v) = self { v } else { 0 } }
    var category: String {
      switch self {
      case .category(let v): v
      case .number(let v): v.hubFormatted()
      case .time(let v): v.formatted(date: .omitted, time: .shortened)
      }
    }
    var time: Date {
      switch self {
      case .time(let v): v
      case .number(let v): Date(timeIntervalSince1970: v / 1000)
      case .category(let v): (try? Date(v, strategy: .iso8601)) ?? .distantPast
      }
    }
  }
  /// Reads `n`, `[x, y]`, `{x, y}` and `{label, value}` points
  func points() -> [Point] {
    var result = [Point]()
    for series in value.series {
      for (index, point) in state.points(series.data).enumerated() {
        let x: AnyCodable?
        let y: Double?
        switch point {
        case .int, .double, .string:
          x = .int(index)
          y = point.double
        case .array(let pair) where pair.count >= 2:
          x = pair[0]
          y = pair[1].double
        case .dictionary(let object):
          x = object["x"] ?? object["label"] ?? .int(index)
          y = (object["y"] ?? object["value"])?.double
        default:
          x = nil
          y = nil
        }
        guard let x, let y else { continue }
        let axis: X
        switch (value.x, x) {
        case (.time, .string(let string)): axis = .time((try? Date(string, strategy: .iso8601)) ?? .distantPast)
        case (.time, _): axis = .time(Date(timeIntervalSince1970: (x.double ?? 0) / 1000))
        case (.category, _), (nil, .string): axis = .category(x.string ?? "")
        default: axis = .number(x.double ?? 0)
        }
        result.append(Point(id: result.count, series: series.name, x: axis, y: y))
      }
    }
    return result
  }
  var axis: Element.Chart.Axis {
    if let x = value.x { return x }
    return points().contains { if case .category = $0.x { true } else { false } } ? .category : .number
  }
  var body: some View {
#if canImport(Charts)
    let points = points()
    let isPie = value.kind == .pie || value.kind == .donut
    // Small widgets have no room for a legend
    let showsLegend = value.legend ?? ((isPie || value.series.count > 1) && widgetSize?.height != 1)
    VStack(alignment: .leading, spacing: 6) {
      if let title = state.text(value.title) {
        Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
      }
      Group {
        if isPie {
          pie(points)
        } else {
          switch axis {
          case .time: marks(points) { $0.time }
          case .category: marks(points) { $0.category }
          case .number: marks(points) { $0.number }
          }
        }
      }.chartLegend(showsLegend ? .visible : .hidden)
        .modifier(WidgetAxes(enabled: widgetSize != nil && !isPie))
        .modifier(SeriesColors(names: value.series.map(\.name), colors: isPie ? [] : value.series.map { state.color($0.color) }))
        .modifier(YDomain(min: value.yMin, max: value.yMax, enabled: !isPie))
        .frame(minHeight: 60)
        .frame(height: widgetSize == nil ? CGFloat(value.height ?? (isPie ? 200 : 180)) : nil)
        .animation(.smooth, value: points.map(\.y))
    }.frame(maxWidth: .infinity, maxHeight: widgetSize == nil ? nil : .infinity)
#else
    Text("Charts aren't available here").foregroundStyle(.secondary)
#endif
  }
#if canImport(Charts)
  @ChartContentBuilder
  func mark<P: Plottable>(_ point: Point, x: P) -> some ChartContent {
    switch value.kind {
    case .bar:
      if value.stacked || value.series.count == 1 {
        BarMark(x: .value("x", x), y: .value(value.unit ?? "y", point.y))
          .foregroundStyle(by: .value("Series", point.series))
      } else {
        BarMark(x: .value("x", x), y: .value(value.unit ?? "y", point.y))
          .foregroundStyle(by: .value("Series", point.series))
          .position(by: .value("Series", point.series))
      }
    case .area:
      AreaMark(x: .value("x", x), y: .value(value.unit ?? "y", point.y), stacking: value.stacked ? .standard : .unstacked)
        .foregroundStyle(by: .value("Series", point.series))
        .interpolationMethod(.catmullRom)
        .opacity(value.stacked ? 0.8 : 0.35)
    default:
      LineMark(x: .value("x", x), y: .value(value.unit ?? "y", point.y))
        .foregroundStyle(by: .value("Series", point.series))
        .interpolationMethod(.catmullRom)
        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
    }
  }
  func marks<P: Plottable>(_ points: [Point], x: @escaping (X) -> P) -> some View {
    Chart(points) { point in
      mark(point, x: x(point.x))
    }
  }
  func pie(_ points: [Point]) -> some View {
    Chart(points) { point in
      SectorMark(angle: .value("Value", point.y), innerRadius: .ratio(value.kind == .donut ? 0.6 : 0), angularInset: 1.5)
        .cornerRadius(3)
        .foregroundStyle(by: .value("Label", point.x.category))
    }
  }
  /// Widgets keep a few y labels inside the tile and drop the x labels
  struct WidgetAxes: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
      if enabled {
        content.chartXAxis(.hidden)
          .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
          .padding(.vertical, 6)
      } else {
        content
      }
    }
  }
  struct SeriesColors: ViewModifier {
    let names: [String]
    let colors: [Color?]
    func body(content: Content) -> some View {
      // Only when every series names its color; otherwise the system palette
      if !colors.isEmpty, colors.allSatisfy({ $0 != nil }) {
        content.chartForegroundStyleScale(domain: names, range: colors.compactMap { $0 })
      } else {
        content
      }
    }
  }
  struct YDomain: ViewModifier {
    let min: Double?
    let max: Double?
    let enabled: Bool
    func body(content: Content) -> some View {
      if enabled, let min, let max, max > min {
        content.chartYScale(domain: min...max)
      } else if enabled, let min {
        content.chartYScale(domain: .automatic(includesZero: min <= 0))
      } else {
        content
      }
    }
  }
#endif
}

// MARK: Table

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
struct HubTableView: View {
  let value: Element.Table
  let state = Element.AppState()
  var body: some View {
    let rows = (state.any(value.data)?.array ?? []).compactMap(\.dictionary)
    ViewThatFits(in: .horizontal) {
      grid(rows)
      ScrollView(.horizontal) { grid(rows) }
    }
  }
  func grid(_ rows: [[String: AnyCodable]]) -> some View {
    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
      GridRow {
        ForEach(value.columns, id: \.key) { column in
          Text(column.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .gridColumnAlignment(column.align?.alignment ?? .leading)
        }
      }
      Divider().gridCellUnsizedAxes(.horizontal)
      ForEach(Array(rows.enumerated()), id: \.offset) { row in
        GridRow {
          ForEach(value.columns, id: \.key) { column in
            cell(row.element[column.key]?.displayText ?? "", style: column.style)
          }
        }
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  @ViewBuilder
  func cell(_ text: String, style: Element.Table.Column.Style?) -> some View {
    switch style {
    case .badge: HubBadge(text: text, color: .status(text))
    case .secondary: Text(text).foregroundStyle(.secondary).lineLimit(1)
    case .monospaced: Text(text).monospaced().lineLimit(1)
    default: Text(text).lineLimit(1)
    }
  }
}

extension Element.Table.Column.Alignment {
  var alignment: HorizontalAlignment {
    switch self {
    case .leading: .leading
    case .center: .center
    case .trailing: .trailing
    }
  }
}

// MARK: Layout

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
struct HubGridView: View {
  let value: Element.Grid
  var body: some View {
    let spacing = value.spacing.map { CGFloat($0) } ?? 12
    let columns: [GridItem] = if let count = value.columns, count > 0 {
      Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .topLeading), count: count)
    } else {
      [GridItem(.adaptive(minimum: CGFloat(value.minWidth ?? 160)), spacing: spacing, alignment: .topLeading)]
    }
    LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) {
      ForEach(value.content) { $0 }
    }
  }
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
struct HubSectionView: View {
  let value: Element.Section
  let state = Element.AppState()
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if value.title != nil || value.subtitle != nil {
        VStack(alignment: .leading, spacing: 2) {
          if let title = state.text(value.title) {
            Text(title).font(.headline)
          }
          if let subtitle = state.text(value.subtitle) {
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
          }
        }
      }
      VStack(alignment: .leading, spacing: 10) {
        ForEach(value.content) { $0 }
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
      .padding(value.style == .card ? 14 : 0)
      .background {
        if value.style == .card {
          RoundedRectangle(cornerRadius: 16).fill(Color.gray.opacity(0.1))
        }
      }
  }
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
struct HubTabsView: View {
  let value: Element.Tabs
  let state = Element.AppState()
  @State private var local: String?
  var selection: Binding<String> {
    Binding {
      if let key = value.selected, let selected = state.any(key)?.string, value.tabs.contains(where: { $0.title == selected }) {
        return selected
      }
      return local ?? value.tabs.first?.title ?? ""
    } set: { title in
      local = title
      if let key = value.selected {
        state.store(.string(title), for: key.hasPrefix("$") ? String(key.dropFirst()) : key)
      }
    }
  }
  var body: some View {
    let selected = selection.wrappedValue
    VStack(alignment: .leading, spacing: 12) {
      Picker("", selection: selection) {
        ForEach(value.tabs, id: \.title) { tab in
          if let icon = tab.icon, value.style == .tabs {
            Label(tab.title, systemImage: icon).tag(tab.title)
          } else {
            Text(tab.title).tag(tab.title)
          }
        }
      }.pickerStyle(.segmented).labelsHidden()
      if let tab = value.tabs.first(where: { $0.title == selected }) {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(tab.content) { $0 }
        }.transition(.opacity)
      }
    }.animation(.smooth, value: selected)
  }
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
struct HubSheetView: View {
  let value: Element.Sheet
  let state = Element.AppState()
  @State private var isPresented = false
  var body: some View {
    let title = state.text(value.title) ?? value.title
    Button {
      isPresented = true
    } label: {
      if let icon = value.icon {
        Label(title, systemImage: icon)
      } else {
        Text(title)
      }
    }.sheet(isPresented: $isPresented) {
      NavigationStack {
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            ForEach(value.content) { $0 }
          }.padding()
        }.navigationTitle(title)
          .toolbar {
            ToolbarItem(placement: .confirmationAction) {
              Button("Done") { isPresented = false }
            }
          }
      }.frame(minWidth: 360, minHeight: 300)
        .environment(state.app)
        .environment(state.nested)
        .environmentObject(state.hub)
        .environment(\.serviceContext, state.context)
    }
  }
}

// MARK: Button

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
struct HubButtonView: View {
  let value: Element.Button
  let state = Element.AppState()
  @State private var isConfirming = false
  var role: ButtonRole? {
    value.style == .destructive || value.confirm?.destructive == true ? .destructive : nil
  }
  var body: some View {
    if let title = state.translate(value.title) {
      Group {
        if value.confirm != nil {
          Button(role: role) {
            isConfirming = true
          } label: {
            label(title)
          }
        } else {
          AsyncButton(role: role) {
            try await state.perform(action: value.action)
          } label: {
            label(title)
          }
        }
      }.modifier(Style(style: value.style))
        .confirmationDialog(state.text(value.confirm?.title) ?? title, isPresented: $isConfirming, titleVisibility: .visible) {
          AsyncButton(role: role) {
            try await state.perform(action: value.action)
          } label: {
            Text(state.text(value.confirm?.button) ?? title)
          }
          Button("Cancel", role: .cancel) {}
        } message: {
          if let message = state.text(value.confirm?.message) {
            Text(message)
          }
        }
    }
  }
  func label(_ title: String) -> TitleLabel {
    TitleLabel(title: title, icon: value.icon)
  }
  struct TitleLabel: View {
    let title: String
    let icon: String?
    var body: some View {
      if let icon {
        Label(title, systemImage: icon)
      } else {
        Text(title)
      }
    }
  }
  struct Style: ViewModifier {
    let style: Element.ButtonStyle?
    func body(content: Content) -> some View {
      switch style {
      case .prominent: content.buttonStyle(.borderedProminent)
      case .bordered, .destructive: content.buttonStyle(.bordered)
      default: content
      }
    }
  }
}

// MARK: List

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
struct HubListView: View {
  let value: Element.List
  let state = Element.AppState()
  var body: some View {
    let rows = (state.any(value.data)?.array ?? []).compactMap(\.dictionary)
    ForEach(Array(rows.enumerated()), id: \.offset) { row in
      HStack {
        value.content
      }.environment(NestedList(data: row.element))
    }
  }
}

// MARK: Routing

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
struct DashboardElementView: View {
  let element: Element
  var body: some View {
    switch element {
    case .markdown(let value): HubMarkdownView(value: value)
    case .image(let value): HubImageView(value: value)
    case .badge(let value): HubBadgeView(value: value)
    case .divider: Divider()
    case .link(let value): HubLinkView(value: value)
    case .stat(let value): HubStatView(value: value)
    case .gauge(let value): HubGaugeView(value: value)
    case .chart(let value): HubChartView(value: value)
    case .table(let value): HubTableView(value: value)
    case .grid(let value): HubGridView(value: value)
    case .section(let value): HubSectionView(value: value)
    case .tabs(let value): HubTabsView(value: value)
    case .sheet(let value): HubSheetView(value: value)
    case .button(let value): HubButtonView(value: value)
    case .list(let value): HubListView(value: value)
    default: Image(systemName: "questionmark.circle.dashed").foregroundStyle(.tertiary)
    }
  }
}
#endif
