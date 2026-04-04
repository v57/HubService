//
//  Transferable.swift
//  Hub
//
//  Created by Linux on 04.04.26.
//

import SwiftUI
import HubService

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
struct FileInfoTransfer: Transferable {
  let hub: HubClient
  let file: FileInfo
  let context: HubContext?
  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation<Self>(exportedContentType: .data) { file in
      try await SentTransferredFile(file.download(), allowAccessingOriginalFile: false)
    }.suggestedFileName { $0.file.name }
  }
  func download() async throws -> URL {
    do {
      return try await UploadManager.main.download(file: file, from: hub, context: context)
    } catch {
      print(error)
      throw error
    }
  }
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
struct DirectoryTransfer: Transferable {
  let hub: HubClient
  let name: String
  let context: HubContext?
  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation<Self>(exportedContentType: .folder) { file in
      try await SentTransferredFile(file.download(), allowAccessingOriginalFile: false)
    }.suggestedFileName { String($0.name.dropLast(1)) }
  }
  func download() async throws -> URL {
    do {
      return try await UploadManager.main.download(directory: name, from: hub, context: context)
    } catch {
      print(error)
      throw error
    }
  }
}
