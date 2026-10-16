import Foundation

/// Exact token metadata only. The cache manager owns synchronization and the
/// lifetime of each UUID's resident state. A match can end inside a compressed
/// edge; its representative always has a stored sequence covering that prefix.
final class PrefixTokenIndex {
  struct Match: Equatable {
    let id: UUID
    let tokenCount: Int
  }

  private struct Representative {
    let id: UUID
    let order: UInt64
  }

  private final class Node {
    // A shared Array value and absolute range avoid copying prefix labels when
    // splitting or merging edges. No node mutates the inserted token buffer.
    var tokens: [Int]
    var range: Range<Int>
    weak var parent: Node?
    var children: [Int: Node] = [:]
    var entries: [UUID: UInt64] = [:]
    var representative: Representative?

    init(tokens: [Int], range: Range<Int>, parent: Node? = nil) {
      self.tokens = tokens
      self.range = range
      self.parent = parent
    }
  }

  private let root = Node(tokens: [], range: 0..<0)
  private var endpoints: [UUID: Node] = [:]
  private var nextOrder: UInt64 = 0

  init() {}

  deinit { removeAll() }

  /// Reinserting an ID replaces its sequence. Among entries with the same
  /// matched length, the most recent insertion wins, including duplicate input.
  /// Empty input removes that ID and creates no zero-length cache entry.
  func insert(tokens: [Int], id: UUID) {
    remove(id: id)
    guard !tokens.isEmpty else { return }

    var node = root
    var position = 0
    while position < tokens.count {
      let first = tokens[position]
      guard let child = node.children[first] else {
        let leaf = Node(tokens: tokens, range: position..<tokens.count, parent: node)
        node.children[first] = leaf
        node = leaf
        break
      }

      let bound = min(child.range.count, tokens.count - position)
      var matched = 0
      while matched < bound,
        tokens[position + matched] == child.tokens[child.range.lowerBound + matched] {
        matched += 1
      }
      if matched == child.range.count {
        position += matched
        node = child
        continue
      }

      // The dictionary lookup matched the edge's first token, so this split
      // always leaves two nonempty labels unless the new input ends here.
      let middle = child.range.lowerBound + matched
      let split = Node(tokens: child.tokens,
        range: child.range.lowerBound..<middle, parent: node)
      split.representative = child.representative
      child.range = middle..<child.range.upperBound
      child.parent = split
      split.children[child.tokens[middle]] = child
      node.children[first] = split
      position += matched
      node = split
    }

    let entry = Representative(id: id, order: nextOrder)
    nextOrder += 1
    node.entries[id] = entry.order
    endpoints[id] = node
    // The new entry is newest throughout this ancestor path; insertion needs
    // no scan over sibling histories to refresh their representatives.
    var ancestor: Node? = node
    while let current = ancestor {
      current.representative = entry
      ancestor = current.parent
    }
  }

  func remove(id: UUID) {
    guard let endpoint = endpoints.removeValue(forKey: id) else { return }
    endpoint.entries.removeValue(forKey: id)

    var current: Node? = endpoint
    while let node = current {
      let parent = node.parent
      if node !== root, let parent, node.entries.isEmpty {
        if node.children.isEmpty {
          parent.children.removeValue(forKey: node.tokens[node.range.lowerBound])
          current = parent
          continue
        }
        if node.children.count == 1, let child = node.children.values.first {
          // Every child buffer includes the complete path from token zero.
          // Adopt its wider range instead of concatenating copied labels.
          node.tokens = child.tokens
          node.range = node.range.lowerBound..<child.range.upperBound
          node.entries = child.entries
          node.children = child.children
          node.representative = child.representative
          for entryID in node.entries.keys { endpoints[entryID] = node }
          for grandchild in node.children.values { grandchild.parent = node }
        }
      }
      if node.representative?.id == id { refreshRepresentative(node) }
      current = parent
    }
  }

  func removeAll() {
    endpoints.removeAll()
    // An index with many prefix endpoints can be deep. Release it iteratively
    // rather than making ARC destroy the complete child chain recursively.
    var pending = [root]
    while let node = pending.popLast() {
      pending.append(contentsOf: node.children.values)
      node.children.removeAll()
      node.entries.removeAll()
      node.representative = nil
      node.parent = nil
    }
    nextOrder = 0
  }

  /// Returns the longest positive exact prefix up to the caller's cap. The
  /// caller can reserve the last input token for logits with tokens.count - 1.
  func longestPrefix(tokens: [Int], maximumCount: Int) -> Match? {
    let limit = min(tokens.count, maximumCount)
    guard limit > 0 else { return nil }
    var node = root
    var position = 0
    while position < limit, let child = node.children[tokens[position]] {
      let bound = min(child.range.count, limit - position)
      var matched = 0
      while matched < bound,
        tokens[position + matched] == child.tokens[child.range.lowerBound + matched] {
        matched += 1
      }
      position += matched
      node = child
      if matched < child.range.count { break }
    }
    guard position > 0, let entry = node.representative else { return nil }
    return Match(id: entry.id, tokenCount: position)
  }

  /// Every live entry with a positive exact match, longest first and newest
  /// insertion first on ties. Resident layer/window eligibility belongs to the
  /// cache manager: a shorter lexical candidate can have the greatest usable KV.
  func matches(tokens: [Int], maximumCount: Int) -> [Match] {
    let limit = min(tokens.count, maximumCount)
    guard limit > 0 else { return [] }
    var candidates: [(match: Match, order: UInt64)] = []
    var node = root
    var position = 0

    while true {
      if position == limit {
        collectEntries(node, tokenCount: position, into: &candidates)
        break
      }
      if position > 0 {
        for (id, order) in node.entries {
          candidates.append((Match(id: id, tokenCount: position), order))
        }
      }
      let first = tokens[position]
      // These subtrees diverge at the next token and share the path up to here.
      if position > 0 {
        for (key, child) in node.children where key != first {
          collectEntries(child, tokenCount: position, into: &candidates)
        }
      }
      guard let child = node.children[first] else { break }
      let bound = min(child.range.count, limit - position)
      var matched = 0
      while matched < bound,
        tokens[position + matched] == child.tokens[child.range.lowerBound + matched] {
        matched += 1
      }
      position += matched
      if matched < child.range.count {
        collectEntries(child, tokenCount: position, into: &candidates)
        break
      }
      node = child
    }
    candidates.sort {
      $0.match.tokenCount == $1.match.tokenCount ? $0.order > $1.order
        : $0.match.tokenCount > $1.match.tokenCount
    }
    return candidates.map(\.match)
  }

  private func collectEntries(_ subtree: Node, tokenCount: Int,
    into candidates: inout [(match: Match, order: UInt64)]) {
    guard tokenCount > 0 else { return }
    var pending = [subtree]
    while let node = pending.popLast() {
      for (id, order) in node.entries {
        candidates.append((Match(id: id, tokenCount: tokenCount), order))
      }
      pending.append(contentsOf: node.children.values)
    }
  }

  private func refreshRepresentative(_ node: Node) {
    var newest: Representative?
    for (id, order) in node.entries {
      if let previous = newest, previous.order >= order { continue }
      newest = Representative(id: id, order: order)
    }
    for child in node.children.values {
      guard let entry = child.representative else { continue }
      if let previous = newest, previous.order >= entry.order { continue }
      newest = entry
    }
    node.representative = newest
  }
}
