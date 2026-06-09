//
//  Storage.swift
//  Hub
//
//  Created by Linux on 13.07.25.
//

import SwiftUI
import UniformTypeIdentifiers
import HubService

private extension HubClient {
  static let test = HubClient(URL(string: "ws://127.0.0.1:1997")!, keyChain: KeyChain())
}

@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
#Preview {
  HubFiles(path: "").environmentObject(HubClient.test)
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
public struct HubFiles: View {
  @EnvironmentObject private var hub: HubClient
  @Environment(\.hubName) private var name
  @State private var context = HubContext()
  @State private var list = FileList(count: 0, files: [], directories: [])
  @State private var selected: Set<String> = []
  @State private var path: String
  @State private var uploadManager = UploadManager.main
  public init(path: String = "") {
    _path = State(initialValue: path)
  }
  public var body: some View {
    NavigationSplitView {
      SelectionList(context: $context)
    } detail: {
#if !os(tvOS) && !os(watchOS)
      if context.service != nil {
        ListView(context: context, list: list, selected: $selected, path: $path).toolbar {
          if !path.isEmpty {
            ToolbarItem(placement: .navigation) {
              Button("Previous", systemImage: "arrow.up.folder") {
                path = path.parentDirectory
              }.flipsForRightToLeftLayoutDirection(true)
            }
          }
          if selected.count > 0 {
            ToolbarItem(placement: .destructiveAction) {
              Button("Delete Selected", systemImage: "trash", role: .destructive) {
                Task {
                  await remove(files: Array(selected))
                }
              }.keyboardShortcut(.delete)
            }
          }
        }.dropDestination { (files: [URL], point: CGPoint) -> Bool in
          add(files: files)
          return true
        }.environment(\.serviceContext, context).modifier(SubtitleModifier(path: path))
          .task(id: HubTask(id: hub.id, path: path, context: context)) {
            do {
              list = FileList(count: 0, files: [], directories: [])
              for try await list: FileList in hub.values("s3/list", path, context: context) {
                self.list = list
              }
            } catch {
              list = FileList(count: 0, files: [], directories: [])
            }
          }.contentTransition(.symbolEffect(.replace)).progressDraw()
          .onChange(of: context.service) { selected = [] }
      }
#endif
    }.navigationTitle("Files").syncProviders(path: "s3/list")
  }
  
  struct SelectionList: View {
    @Environment(\.serviceProviders) private var providers
    @Binding var context: HubContext
    var body: some View {
      List(selection: $context.service) {
        Section("Locations") {
          ForEach(providers) { provider in
            Label(provider.name ?? "Storage", systemImage: "externaldrive")
          }
        }
      }.task(id: context.service == nil && !providers.isEmpty) {
        guard context.service == nil && !providers.isEmpty else { return }
        context.service = providers.first?.id
      }
    }
  }
  
  @available(iOS 17.0, macOS 14.0, *)
  @available(tvOS, unavailable)
  @available(watchOS, unavailable)
  struct ListView: View {
    @EnvironmentObject private var hub: HubClient
    @Environment(\.hubName) private var name
    let context: HubContext
    let list: FileList
    @Binding var selected: Set<String>
    @Binding var path: String
    @State private var uploadManager = UploadManager.main
    @State private var sortOrder = [
      KeyPathComparator(\FileInfo.name, comparator: .localized)
    ]
    
    private var directories: [FileInfo] {
      uploadManager.directories(for: hub, at: path, with: list.directories, context: context)
        .map { FileInfo(path: path + $0, size: 0, lastModified: nil) }
        .sorted(using: sortOrder)
    }
    private var files: [FileInfo] {
      uploadManager.files(for: hub, at: path, with: list.files, context: context)
        .sorted(using: sortOrder)
    }
    var body: some View {
      Table(of: FileInfo.self, selection: $selected, sortOrder: $sortOrder) {
        TableColumn("Name", value: \FileInfo.name) { (file: FileInfo) in
          NameView(file: file, path: path).tint(selected.contains(file.name) ? .white : .blue)
        }
        TableColumn("Size", value: \FileInfo.size) { (file: FileInfo) in
          Text(file.size.bytesString)
            .foregroundStyle(.secondary)
        }.width(60)
        TableColumn("Last Modified", value: \FileInfo.lastModified) { (file: FileInfo) in
          if let date = file.lastModified {
            Text(date, format: .dateTime).foregroundStyle(.secondary)
          } else {
            Text("")
          }
        }.width(110)
      } rows: {
        ForEach(directories, id: \.self) { file in
          TableRow(file).draggable(DirectoryTransfer(hub: hub, name: file.name, context: context))
        }
        ForEach(files) { file in
          TableRow(file).draggable(FileInfoTransfer(hub: hub, file: file, context: context))
        }
      }.contextMenu(forSelectionType: String.self) { (files: Set<String>) in
        if files.count == 1, let file = files.first, file.last != "/" {
          Button("Copy temporary link", systemImage: "link") {
            Task {
              let link: String = try await hub.send("s3/read", path + file, context: context)
              link.copyToClipboard()
            }
          }
        }
        Button("Delete", systemImage: "trash", role: .destructive) {
          Task { await remove(files: Array(files)) }
        }.keyboardShortcut(.delete)
      } primaryAction: { files in
        if files.count == 1, let file = files.first, file.hasSuffix("/") {
          guard !file.isEmpty else { return }
          if file.hasPrefix("/") {
            path = path.parentDirectory
          } else {
            path += file
          }
        }
      }
    }
    func remove(files: [String]) async {
      do {
        for file in files {
          try await hub.send("s3/delete", path + file, context: context)
        }
      } catch { print(error) }
    }
  }
  func add(files: [URL]) {
    uploadManager.upload(files: files, directory: path, to: hub, context: context)
  }
  func remove(files: [String]) async {
    do {
      for file in files {
        try await hub.send("s3/delete", path + file, context: context)
      }
    } catch { print(error) }
  }
  struct SubtitleModifier: ViewModifier {
    let path: String
    private var directoryName: String {
      String(path.dropLast(1))
    }
    func body(content: Content) -> some View {
#if os(tvOS) || os(visionOS) || os(watchOS)
      content
#else
      if #available(iOS 26.0, *) {
        content.navigationSubtitle(Text(directoryName))
      } else {
        content
      }
#endif
    }
  }
  // MARK: File name view
  struct NameView: View {
    let file: FileInfo
    let path: String
    var body: some View {
      if file.name.first == "/" {
        HStack(spacing: 0) {
          Image(systemName: "chevron.left")
            .frame(minWidth: 25)
          Text(name.dropFirst())
        }.foregroundStyle(.tint).fontWeight(.medium)
      } else if file.name.first == "$" {
        HStack(spacing: 0) {
          Image(systemName: "display")
            .frame(minWidth: 25)
          Text(name.dropFirst())
        }.foregroundStyle(.tint).fontWeight(.medium)
      } else {
        HStack(spacing: 0) {
          IconView(file: file, path: path)
            .foregroundStyle(.tint)
            .frame(minWidth: 25)
          Text(name).contentTransition(.numericText()).animation(.smooth, value: name)
        }
      }
    }
    struct IconView: View {
      @EnvironmentObject private var hub: HubClient
      @Environment(\.serviceContext) private var context
      @State private var uploadManager = UploadManager.main
      
      let file: FileInfo
      let path: String
      var body: some View {
        let progress = uploadManager.progress(for: hub, at: path + file.name, context: context)
        let isCompleted: Bool = progress == 1
        Image(systemName: isCompleted ? "checkmark" : icon, variableValue: progress)
          .symbolVariant(progress != nil ? .circle : .fill)
      }
      var icon: String {
        file.isDirectory ? "folder" : fileIcon
      }
      var fileIcon: String {
        switch file.name.fileType {
        case .image: "photo"
        case .video: "film"
        case .audio: "speaker.wave.2"
        case .document: "document"
        }
      }
    }
    var name: String {
      file.isDirectory ? String(file.name.dropLast(1)) : file.name
    }
  }
}


struct FileList: Decodable {
  let count: Int
  var files: [FileInfo]
  var directories: [String]
}
struct FileInfo: Identifiable, Hashable, Decodable {
  let name: String
  let path: String
  let size: Int
  let lastModified: Date?
  
  var id: String { name }
  let isDirectory: Bool
  var ext: String {
    isDirectory ? "" : String(name.split { $0 == "." }.last!)
  }
  init(path: String, size: Int, lastModified: Date?) {
    if let last = path.split(separator: "/").last(where: { !$0.isEmpty }) {
      self.name = String(last)
    } else {
      self.name = path
    }
    self.path = path
    self.size = size
    self.lastModified = lastModified
    self.isDirectory = path.last == "/"
  }
}

// MARK: Extensions
extension Optional: @retroactive Comparable where Wrapped == Date {
  public static func < (lhs: Optional, rhs: Optional) -> Bool {
    guard let lhs, let rhs else { return false }
    return lhs < rhs
  }
}

public extension URL {
  func contents(array: inout [URL]) {
    if hasDirectoryPath {
      let content = (try? FileManager.default.contentsOfDirectory(at: self, includingPropertiesForKeys: nil)) ?? []
      for url in content {
        url.contents(array: &array)
      }
    } else {
      array.append(self)
    }
  }
  @available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
  var fileExists: Bool {
    FileManager.default.fileExists(atPath: path(percentEncoded: false))
  }
  @available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
  var fileSize: Int64 {
    (try? FileManager.default.attributesOfItem(atPath: path(percentEncoded: false))[FileAttributeKey.size] as? Int64) ?? 0
  }
  func delete() {
    try? FileManager.default.removeItem(at: self)
  }
}
public extension Int {
  var bytesString: String {
    guard self > 0 else { return "" }
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: Int64(self))
  }
}
public extension String {
  var parentDirectory: String {
    guard !isEmpty else { return self }
    let c = components(separatedBy: "/")
    let d = c.prefix(c.last == "" ? c.count - 2 : c.count - 1).joined(separator: "/")
    return d.isEmpty ? d : d + "/"
  }
  enum FileType {
    case image, video, audio, document
  }
  var fileType: FileType {
    switch components(separatedBy: ".").last?.lowercased() {
    case "png", "jpg", "jpeg", "heic", "avif": .image
    case "mp4", "mov", "mkv", "avi": .video
    case "wav", "ogg", "acc", "m4a", "mp3": .audio
    default: .document
    }
  }
}

public extension View {
  @ViewBuilder
  func progressDraw() -> some View {
    if #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, *, visionOS 26.0, *) {
      self.symbolVariableValueMode(.draw)
    } else {
      self
    }
  }
}
extension String {
  func copyToClipboard() {
    #if os(macOS)
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(self, forType: .string)
    #elseif os(watchOS)
    #elseif os(iOS)
    UIPasteboard.general.string = self
    #endif
  }
}
