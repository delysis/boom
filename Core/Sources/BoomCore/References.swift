import Foundation

public struct WikiReference: Equatable, Sendable {
  public let title: String
  public let documentID: UUID?
  public init(title: String, documentID: UUID? = nil) {
    self.title = title
    self.documentID = documentID
  }
}
public enum ReferenceParser {
  /// Strip Markdown code and escaped characters before looking for references.
  /// Deliberately conservative: malformed/open code fences suppress links to EOF.
  public static func visibleText(_ text: String) -> String {
    var output = ""
    var fence: Character?
    var fenceWidth = 0
    var inlineWidth = 0
    for line in text.components(separatedBy: "\n") {
      let leading = line.prefix { $0 == " " }.count
      let stripped = line.dropFirst(min(leading, 3))
      if inlineWidth == 0, leading <= 3, let c = stripped.first, c == "`" || c == "~" {
        let n = stripped.prefix { $0 == c }.count
        if n >= 3 {
          if fence == nil {
            fence = c
            fenceWidth = n
          } else if fence == c && n >= fenceWidth
            && stripped.dropFirst(n).trimmingCharacters(in: .whitespaces).isEmpty
          {
            fence = nil
          }
          output += "\n"
          continue
        }
      }
      guard fence == nil, !line.hasPrefix("    "), !line.hasPrefix("\t") else {
        output += "\n"
        continue
      }
      var i = line.startIndex
      while i < line.endIndex {
        let c = line[i]
        if c == "\\", inlineWidth == 0 {
          i = line.index(after: i)
          if i < line.endIndex { i = line.index(after: i) }
          output += " "
          continue
        }
        if c == "`" {
          var j = i
          while j < line.endIndex && line[j] == "`" { j = line.index(after: j) }
          let n = line.distance(from: i, to: j)
          if inlineWidth == 0 { inlineWidth = n } else if n == inlineWidth { inlineWidth = 0 }
          output += " "
          i = j
          continue
        }
        if inlineWidth == 0 { output.append(c) }
        i = line.index(after: i)
      }
      output += "\n"
    }
    return output
  }
  public static func wiki(_ text: String) throws -> [WikiReference] {
    let visible = visibleText(text)
    let ns = visible as NSString
    let regex = try NSRegularExpression(pattern: #"\[\[([^\[\]\n]{1,256})\]\]"#)
    var result: [WikiReference] = []
    for match in regex.matches(in: visible, range: NSRange(location: 0, length: ns.length)) {
      let body = ns.substring(with: match.range(at: 1))
      let p = body.split(separator: "|", omittingEmptySubsequences: false)
      guard p.count <= 2, !p[0].trimmingCharacters(in: .whitespaces).isEmpty else {
        throw BoomError.invalid("Malformed document reference: \(body)")
      }
      let title = p[0].trimmingCharacters(in: .whitespaces)
      if p.count == 2 {
        guard let id = UUID(uuidString: String(p[1])) else {
          throw BoomError.invalid("A stable wiki reference must end with a document UUID: \(body)")
        }
        result.append(WikiReference(title: title, documentID: id))
      } else {
        result.append(WikiReference(title: title))
      }
    }
    return result
  }
  public static func personas(_ text: String) throws -> [String] {
    let visible = visibleText(text)
    let ns = visible as NSString
    let regex = try NSRegularExpression(
      pattern: #"(?<![\p{L}\p{N}_@./:-])@([a-z][a-z0-9_-]{0,47})(?![a-z0-9_-])"#)
    var seen = Set<String>()
    return regex.matches(in: visible, range: NSRange(location: 0, length: ns.length)).compactMap {
      m in
      let slug = ns.substring(with: m.range(at: 1))
      return seen.insert(slug).inserted ? slug : nil
    }
  }
}
public struct ContextPlan: Equatable, Sendable {
  public let documents: [DocumentSnapshot]
  public let fingerprint: String
  public var text: String {
    documents.map { d in
      "DOCUMENT \(d.title)\nID \(d.id.uuidString)\nREVISION \(d.revision)\n" + d.text
    }.joined(separator: "\n\n")
  }
  public var sources: [SourceReference] {
    documents.map {
      SourceReference(id: $0.id, title: $0.title, digest: $0.revision, kind: "document")
    }
  }
  public func revalidate(against current: [DocumentSnapshot]) throws {
    for d in documents {
      guard current.first(where: { $0.id == d.id })?.revision == d.revision else {
        throw BoomError.stale("Referenced document \(d.title)")
      }
    }
  }
}
public enum ContextGraph {
  public struct Limits: Sendable {
    public var depth = 8, documents = 24, bytes = 262_144
    public init(depth: Int = 8, documents: Int = 24, bytes: Int = 262_144) {
      self.depth = depth
      self.documents = documents
      self.bytes = bytes
    }
  }
  /// A chat reads its explicitly attached document and references written in
  /// the current request. Selecting a document elsewhere does not change this.
  public static func resolveChat(
    request: String, attachedDocumentID: UUID?, all: [DocumentSnapshot],
    limits: Limits = Limits()
  ) throws -> ContextPlan {
    let attachment = attachedDocumentID.map { "[[document|\($0.uuidString)]]\n" } ?? ""
    let root = DocumentSnapshot(title: "Chat references", text: attachment + request)
    return try resolve(root: root, all: all, limits: limits)
  }
  public static func resolve(
    root: DocumentSnapshot, all: [DocumentSnapshot], includeRoot: Bool = false,
    limits: Limits = Limits()
  ) throws -> ContextPlan {
    guard Set(all.map(\.id)).count == all.count else {
      throw BoomError.invalid("Duplicate document IDs.")
    }
    var docs = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    docs[root.id] = root
    var active = Set<UUID>()
    var done = Set<UUID>()
    var ordered: [DocumentSnapshot] = []
    var bytes = 0
    func visit(_ d: DocumentSnapshot, _ depth: Int) throws {
      guard !active.contains(d.id) else {
        throw BoomError.invalid("Document-follow cycle at \(d.title).")
      }
      if done.contains(d.id) { return }
      guard depth <= limits.depth else {
        throw BoomError.budget("Document-follow depth exceeds \(limits.depth).")
      }
      active.insert(d.id)
      for ref in try ReferenceParser.wiki(d.text) {
        let target: DocumentSnapshot
        if let id = ref.documentID {
          guard let found = docs[id] else {
            throw BoomError.invalid("Missing linked document: \(ref.title)")
          }
          target = found
        } else {
          let matches = docs.values.filter {
            $0.title.compare(ref.title, options: [.caseInsensitive, .diacriticInsensitive])
              == .orderedSame
          }
          guard matches.count == 1, let found = matches.first else {
            throw BoomError.invalid(
              "Missing or ambiguous document: \(ref.title). Insert its stable link from the picker."
            )
          }
          target = found
        }
        try visit(target, depth + 1)
      }
      active.remove(d.id)
      done.insert(d.id)
      if includeRoot || d.id != root.id {
        bytes += d.text.utf8.count
        guard bytes <= limits.bytes, ordered.count < limits.documents else {
          throw BoomError.budget(
            "Linked context exceeds \(limits.documents) documents / \(limits.bytes) bytes.")
        }
        ordered.append(d)
      }
    }
    try visit(root, 0)
    struct Part: Codable {
      let id: UUID
      let revision: String
    }
    return ContextPlan(
      documents: ordered,
      fingerprint: try Digest.identity(ordered.map { Part(id: $0.id, revision: $0.revision) }))
  }
}
