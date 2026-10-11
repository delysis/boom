import BoomCore
import Foundation

struct CapturedDocumentAuthority: Codable, Sendable {
  let mode: InteractionMode
  let target: DocumentSnapshot?
  static let readOnly = CapturedDocumentAuthority(mode: .ask, target: nil)
}

/// Versioned projection and byte ranges, never an edit permission or KV archive.
struct RenderedReferenceContext: Codable, Sendable {
  let schema: Int
  let promptContract: ConsultationPromptContract
  let prompt: String
  let bodyBytes: Int
  let bindings: [ReferenceContextBinding]
  let target: ReferenceTargetBinding?
}
struct ReferenceContextBinding: Codable, Sendable {
  let source: SourceReference
  let start: Int
  let end: Int
  let rootDigest: String?
  let transform: String?
  let coverage: String?
}
struct ReferenceTargetBinding: Codable, Sendable {
  let documentID: UUID
  let revision: String
  let tag: String
}
private struct ReferenceAttachmentInput: Codable {
  let source: SourceReference
  let text: String
  let rootDigest: String
  let transform: String?
  let coverage: String
}

struct DocumentResponse: Decodable {
  let reply: String
  let edits: [DocumentPatch]
  let issue: String?
}

extension AssistantEnvelope {
  static func decode(_ text: String) throws -> Self {
    try ProductCore.call(["op": "decode_edit_response", "text": text])
  }
}

/// Document policy lives in Rust. Swift only adapts native document and range types.
enum DocumentTools {
  private struct Edit: Decodable {
    let location: Int
    let length: Int
    let replacement: String
  }
  private struct Plan: Decodable { let document: DocumentSnapshot; let edits: [Edit] }
  static func plan(_ patch: DocumentPatch, grant: DocumentGrant, current: DocumentSnapshot) throws -> (DocumentSnapshot, [ValidatedEdit]) {
    let plan: Plan = try ProductCore.call(request("plan_document_patch", patch, grant, current))
    return (plan.document, plan.edits.map { ValidatedEdit(range: NSRange(location: $0.location, length: $0.length), replacement: $0.replacement) })
  }
  static func response(_ text: String, authority: CapturedDocumentAuthority) throws -> DocumentResponse {
    try ProductCore.call(["op": "parse_document_response", "text": text, "authority": try ProductCore.object(authority)])
  }
  static func context(_ documents: [DocumentSnapshot], authority: CapturedDocumentAuthority) throws -> String {
    try ProductCore.call(["op": "render_document_context", "documents": try ProductCore.object(documents),
      "authority": try ProductCore.object(authority)])
  }
  static func renderedContext(_ documents: [DocumentSnapshot], attachments: [AttachmentRecord],
    authority: CapturedDocumentAuthority) throws -> RenderedReferenceContext {
    let extracted = attachments.filter { !$0.text.isEmpty }.map {
      ReferenceAttachmentInput(source: $0.reference, text: $0.text, rootDigest: $0.rootDigest,
        transform: $0.transform, coverage: $0.coverage)
    }
    return try ProductCore.call(["op": "render_document_context", "documents": try ProductCore.object(documents),
      "attachments": try ProductCore.object(extracted), "authority": try ProductCore.object(authority),
      "promptContract": ConsultationPromptContract.referenceBindingsV3.rawValue])
  }
  static func validate(_ patch: DocumentPatch, grant: DocumentGrant, current: DocumentSnapshot) throws -> [ValidatedEdit] {
    let edits: [Edit] = try ProductCore.call(request("validate_document_patch", patch, grant, current))
    return edits.map { ValidatedEdit(range: NSRange(location: $0.location, length: $0.length), replacement: $0.replacement) }
  }
  static func apply(_ patch: DocumentPatch, grant: DocumentGrant, current: DocumentSnapshot) throws -> DocumentSnapshot {
    try ProductCore.call(request("apply_document_patch", patch, grant, current))
  }
  private static func request(_ operation: String, _ patch: DocumentPatch, _ grant: DocumentGrant, _ current: DocumentSnapshot) throws -> [String: Any] {
    ["op": operation, "patch": try ProductCore.object(patch),
      "authority": try ProductCore.object(CapturedDocumentAuthority(mode: grant.mode, target: grant.snapshot)),
      "current": try ProductCore.object(current)]
  }
}
