import BoomCore
import Foundation

/// The proposed fresh SQL settings record. Content/catalog records require
/// their separately admitted SQL ports; this value cannot contain document/chat text,
/// proposal snapshots, voice examples, attachments or every owner's draft.
/// It is not a decoder/migration for the shipped WorkspaceState format.
struct WorkspaceSettings: Codable, Sendable {
  static let maximumEncodedBytes = 16_384
  var schema: UInt8 = 3
  var selectedDocument: UUID?
  var selectedChat: UUID?
  var showLibrary = true
  var showDocument = true
  var showChat = true
  var autocomplete = true
  var preferredModels: [String: String] = [:]
  var writingExampleIDs: [UUID] = []
  var theme = "system"

  /// Preserves nil versus present-empty legacy collections during an explicit
  /// authenticated public conversion, without loading their contents at open.
  var presentOptionalCollections: [String] = []
  func admitScalars() throws {
    guard schema == 3, ["system", "light", "dark"].contains(theme),
      writingExampleIDs.count <= 32, Set(writingExampleIDs).count == writingExampleIDs.count,
      preferredModels.count <= 2,
      preferredModels.allSatisfy({ ["writing", "consultation"].contains($0.key) && $0.value.utf8.count <= 4_096 }),
      presentOptionalCollections.count <= 6, Set(presentOptionalCollections).count == presentOptionalCollections.count,
      presentOptionalCollections.allSatisfy({ ["preferredModels", "importedFolders", "importedFiles", "recordingDrafts", "composerDrafts", "writingExampleIDs"].contains($0) }) else {
      throw BoomError.invalid("Workspace settings identity or pre-encoding scalar bound changed.")
    }
  }
  func validate(documentExists: (UUID) throws -> Bool,
    chatExists: (UUID) throws -> Bool) throws {
    try admitScalars()
    // The receiving reader must enforce this same bound before allocating or
    // decoding. Encoding here admits an already bounded caller-authored value;
    // it is not a reader of the compatibility WorkspaceState blob.
    guard try JSONEncoder().encode(self).count <= Self.maximumEncodedBytes else {
      throw BoomError.budget("Workspace settings exceed their encoded record bound.")
    }
    if let selectedDocument {
      guard try documentExists(selectedDocument) else {
        throw BoomError.invalid("Selected document is absent from the actual SQL index.")
      }
    }
    if let selectedChat {
      guard try chatExists(selectedChat) else {
        throw BoomError.invalid("Selected chat is absent from the actual SQL index.")
      }
    }
    for id in writingExampleIDs {
      guard try documentExists(id) else {
        throw BoomError.invalid("An ordered writing example is absent from the actual SQL index.")
      }
    }
  }
}
