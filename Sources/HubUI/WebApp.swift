//
//  WebApp.swift
//  HubUI
//
//  A service app that is a web page (Docs/Apps/ui.md, "Web apps"). The page stays on its declared origins:
//  leaving them asks the user and opens the browser. Pages on the app's own origin get `window.hub`:
//  `hub.token()` returns a signed page token from `<app path>/token`, and `hub.send(path, body)` calls
//  the hub as the user, only for paths under `<app path>/`.
//

#if canImport(WebKit)
import SwiftUI
import WebKit
import HubService

@available(iOS 17.0, macOS 14.0, *)
public struct HubWebAppView: View {
  @EnvironmentObject private var hub: HubClient
  let header: AppHeader
  @State private var page: HubWebPage?
  @Environment(\.openURL) private var openURL
  public init(header: AppHeader) {
    self.header = header
  }
  public var body: some View {
    Group {
      if let page {
        HubWebPage.Representable(page: page)
          .safeAreaInset(edge: .top, spacing: 0) {
            AddressBar(page: page)
          }
          .alert("Leave \(header.name)?", isPresented: Binding { page.leaving != nil } set: { if !$0 { page.leaving = nil } }) {
            Button("Open in Browser") {
              if let url = page.leaving { openURL(url) }
              page.leaving = nil
            }
            Button("Stay", role: .cancel) { page.leaving = nil }
          } message: {
            Text("The page wants to open \(page.leaving?.host() ?? page.leaving?.absoluteString ?? ""), which isn't part of this app.")
          }
      } else {
        ContentUnavailableView("No page", systemImage: "globe", description: Text("\(header.name) doesn't give a valid page address."))
      }
    }.navigationTitle(header.name)
      .task(id: HubTask(id: hub.id, path: header.path, context: HubContext())) {
        guard let web = header.web, let url = web.url(hub: hub.currentURL) else { return }
        page = HubWebPage(header: header, url: url, origins: web.origins ?? [], hub: hub)
      }
  }
  struct AddressBar: View {
    let page: HubWebPage
    var body: some View {
      HStack(spacing: 6) {
        Image(systemName: page.isSecure ? "lock.fill" : "lock.open")
          .foregroundStyle(page.isSecure ? Color.secondary : Color.orange)
        Text(page.host).lineLimit(1).truncationMode(.middle)
        Spacer(minLength: 0)
        if page.isLoading {
          ProgressView().controlSize(.small)
        }
        Button("Reload", systemImage: "arrow.clockwise") {
          page.webView.reload()
        }.labelStyle(.iconOnly).buttonStyle(.borderless)
      }.font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.bar)
    }
  }
}

@available(iOS 17.0, macOS 14.0, *)
@MainActor
@Observable
final class HubWebPage: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {
  let header: AppHeader
  let url: URL
  /// Origins the page may load in the main frame; the first one is the app's own
  let origins: [Origin]
  @ObservationIgnored let hub: HubClient
  @ObservationIgnored private(set) var webView: WKWebView!
  /// A navigation off the app's origins, waiting for the user
  var leaving: URL?
  var host: String
  var isSecure: Bool
  var isLoading = false
  @ObservationIgnored private var token: (value: String, expires: Date)?

  struct Origin: Hashable {
    let scheme: String
    let host: String
    let port: Int
    init?(_ url: URL) {
      guard let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased() else { return nil }
      self.scheme = scheme
      self.host = host
      self.port = url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : 0)
    }
    init(_ origin: WKSecurityOrigin) {
      scheme = origin.protocol.lowercased()
      host = origin.host.lowercased()
      port = origin.port != 0 ? origin.port : (scheme == "https" ? 443 : scheme == "http" ? 80 : 0)
    }
  }

  init(header: AppHeader, url: URL, origins: [String], hub: HubClient) {
    self.header = header
    self.url = url
    self.origins = [Origin(url)].compactMap { $0 } + origins.compactMap { URL(string: $0).flatMap(Origin.init) }
    self.hub = hub
    host = url.host() ?? url.absoluteString
    isSecure = url.scheme == "https"
    super.init()
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let script = WKUserScript(source: Self.bridge(path: header.path, name: header.name), injectionTime: .atDocumentStart, forMainFrameOnly: true)
    configuration.userContentController.addUserScript(script)
    configuration.userContentController.addScriptMessageHandler(WeakHandler(page: self), contentWorld: .page, name: "hub")
    webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = self
    webView.uiDelegate = self
#if DEBUG
    webView.isInspectable = true
#endif
    webView.load(URLRequest(url: url))
  }

  static func bridge(path: String, name: String) -> String {
    let json = { (value: String) in
      (try? String(data: JSONEncoder().encode(value), encoding: .utf8)) ?? "\"\""
    }
    return """
    (() => {
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.hub
      if (!handler) return
      window.hub = Object.freeze({
        app: \(json(path)),
        name: \(json(name)),
        token: () => handler.postMessage({ type: 'token' }),
        send: (path, body) => handler.postMessage({ type: 'send', path, body: body === undefined ? null : body }),
      })
      window.dispatchEvent(new Event('hubready'))
    })()
    """
  }

  func allows(_ url: URL) -> Bool {
    guard let origin = Origin(url) else { return false }
    return origins.contains(origin)
  }

  // MARK: Navigation

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
    guard let url = navigationAction.request.url else { return .cancel }
    // Frames inside the page load freely; they never get the bridge
    if navigationAction.targetFrame?.isMainFrame == false { return .allow }
    if url.scheme == "about" || url.scheme == "blob" { return .allow }
    if allows(url) { return .allow }
    leaving = url
    return .cancel
  }
  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    // Links that open new windows stay in this view when they are allowed
    if let url = navigationAction.request.url {
      if allows(url) {
        webView.load(URLRequest(url: url))
      } else {
        leaving = url
      }
    }
    return nil
  }
  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    isLoading = true
  }
  func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    if let url = webView.url {
      host = url.host() ?? url.absoluteString
      isSecure = url.scheme == "https" && webView.hasOnlySecureContent
    }
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    isLoading = false
    isSecure = webView.url?.scheme == "https" && webView.hasOnlySecureContent
  }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
    isLoading = false
  }
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
    isLoading = false
  }

  // MARK: Bridge

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
    // Only the app's own origin, in the main frame, may use the hub
    guard message.frameInfo.isMainFrame, Origin(message.frameInfo.securityOrigin) == origins.first else {
      return (nil, "This page isn't allowed to use the hub")
    }
    guard let body = message.body as? [String: Any], let type = body["type"] as? String else {
      return (nil, "Unknown request")
    }
    do {
      switch type {
      case "token":
        guard header.web?.token == true else { return (nil, "This app has no page tokens") }
        return (try await pageToken(), nil)
      case "send":
        guard let path = body["path"] as? String, path.hasPrefix(header.path + "/") else {
          return (nil, "Pages can only call paths under \(header.path)/")
        }
        let input = try JSONDecoder().decode(AnyCodable.self, from: JSONSerialization.data(withJSONObject: body["body"] ?? NSNull(), options: .fragmentsAllowed))
        let output: AnyCodable = try await hub.send(path, input)
        return (try JSONSerialization.jsonObject(with: JSONEncoder().encode(output), options: .fragmentsAllowed), nil)
      default:
        return (nil, "Unknown request \(type)")
      }
    } catch {
      return (nil, String(describing: error))
    }
  }
  /// A cached token while it has 30 seconds left
  func pageToken() async throws -> String {
    if let token, token.expires.timeIntervalSinceNow > 30 { return token.value }
    let value: String = try await hub.send(header.path + "/token")
    token = (value, Self.expiry(token: value) ?? Date().addingTimeInterval(60))
    return value
  }
  static func expiry(token: String) -> Date? {
    guard var payload = token.split(separator: ".").first.map(String.init) else { return nil }
    payload = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
    guard let data = Data(base64Encoded: payload),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let exp = object["exp"] as? Double else { return nil }
    return Date(timeIntervalSince1970: exp)
  }

  /// The content controller keeps its handlers, which would keep the page alive
  final class WeakHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var page: HubWebPage?
    init(page: HubWebPage) { self.page = page }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
      guard let page else { return (nil, "The page is closed") }
      return await page.userContentController(userContentController, didReceive: message)
    }
  }

#if os(macOS)
  struct Representable: NSViewRepresentable {
    let page: HubWebPage
    func makeNSView(context: Context) -> WKWebView { page.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
  }
#else
  struct Representable: UIViewRepresentable {
    let page: HubWebPage
    func makeUIView(context: Context) -> WKWebView { page.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
  }
#endif
}
#endif
