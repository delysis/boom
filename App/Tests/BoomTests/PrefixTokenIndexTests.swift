import Foundation
import XCTest
@testable import Boom

final class PrefixTokenIndexTests: XCTestCase {
  private struct Oracle {
    struct Entry {
      let tokens: [Int]
      let order: Int
    }
    var entries: [UUID: Entry] = [:]
    var nextOrder = 0

    mutating func insert(_ tokens: [Int], id: UUID) {
      if tokens.isEmpty { entries.removeValue(forKey: id); return }
      entries[id] = Entry(tokens: tokens, order: nextOrder)
      nextOrder += 1
    }

    func matches(_ tokens: [Int], maximumCount: Int) -> [PrefixTokenIndex.Match] {
      guard maximumCount > 0 else { return [] }
      var result: [(match: PrefixTokenIndex.Match, order: Int)] = []
      for (id, entry) in entries {
        let limit = min(min(tokens.count, maximumCount), entry.tokens.count)
        var count = 0
        while count < limit, tokens[count] == entry.tokens[count] { count += 1 }
        if count > 0 {
          result.append((PrefixTokenIndex.Match(id: id, tokenCount: count), entry.order))
        }
      }
      return result.sorted {
        $0.match.tokenCount == $1.match.tokenCount ? $0.order > $1.order
          : $0.match.tokenCount > $1.match.tokenCount
      }.map(\.match)
    }
  }

  private struct Generator {
    var state: UInt64 = 0x243f6a8885a308d3
    mutating func next(_ bound: Int) -> Int {
      state = state &* 6364136223846793005 &+ 1442695040888963407
      return Int((state >> 32) % UInt64(bound))
    }
  }

  private func id(_ value: Int) -> UUID {
    UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      UInt8((value >> 24) & 255), UInt8((value >> 16) & 255),
      UInt8((value >> 8) & 255), UInt8(value & 255)))
  }

  private func assertMatch(_ index: PrefixTokenIndex, oracle: Oracle,
    tokens: [Int], maximumCount: Int, file: StaticString = #filePath, line: UInt = #line) {
    let actual = index.longestPrefix(tokens: tokens, maximumCount: maximumCount)
    let expected = oracle.matches(tokens, maximumCount: maximumCount)
    XCTAssertEqual(actual, expected.first,
      "query count \(tokens.count), cap \(maximumCount)", file: file, line: line)
    let all = index.matches(tokens: tokens, maximumCount: maximumCount)
    XCTAssertEqual(all, expected, "All resident candidates must remain reachable.", file: file, line: line)
    XCTAssertEqual(Set(all.map(\.id)).count, all.count, "Each entry appears once.", file: file, line: line)
    guard let actual else { return }
    guard let stored = oracle.entries[actual.id] else {
      XCTFail("Returned a removed or unknown entry ID.", file: file, line: line)
      return
    }
    XCTAssertGreaterThan(actual.tokenCount, 0, file: file, line: line)
    XCTAssertLessThanOrEqual(actual.tokenCount, min(tokens.count, maximumCount),
      file: file, line: line)
    XCTAssertGreaterThanOrEqual(stored.tokens.count, actual.tokenCount, file: file, line: line)
    XCTAssertTrue(stored.tokens.starts(with: tokens.prefix(actual.tokenCount)),
      file: file, line: line)
  }

  func testEmptyInputCapsAndExactIntegerTokens() {
    let index = PrefixTokenIndex()
    XCTAssertNil(index.longestPrefix(tokens: [1], maximumCount: 1))
    index.insert(tokens: [], id: id(1))
    index.remove(id: id(999))
    let tokens = [Int.min, 0, Int.max, -1]
    index.insert(tokens: tokens, id: id(1))
    XCTAssertNil(index.longestPrefix(tokens: [], maximumCount: 10))
    for cap in [Int.min, -1, 0] {
      XCTAssertNil(index.longestPrefix(tokens: tokens, maximumCount: cap))
    }
    XCTAssertNil(index.longestPrefix(tokens: [0], maximumCount: 1))
    XCTAssertEqual(index.longestPrefix(tokens: tokens, maximumCount: 3),
      .init(id: id(1), tokenCount: 3))
    XCTAssertEqual(index.longestPrefix(tokens: tokens, maximumCount: Int.max),
      .init(id: id(1), tokenCount: 4))
    index.insert(tokens: [], id: id(1))
    XCTAssertNil(index.longestPrefix(tokens: tokens, maximumCount: 4))
  }

  func testInteriorDivergenceAndCapsThroughSixteenKTokens() {
    let index = PrefixTokenIndex()
    let tokens = Array(0..<16_384)
    index.insert(tokens: tokens, id: id(1))
    let boundaries = [1, 2, 3, 31, 32, 33, 63, 64, 65, 127, 128, 129,
      255, 256, 257, 511, 512, 513, 1023, 1024, 1025, 4095, 4096, 4097,
      8191, 8192, 8193, 16_383, 16_384]
    for count in boundaries {
      XCTAssertEqual(index.longestPrefix(tokens: tokens, maximumCount: count),
        .init(id: id(1), tokenCount: count))
      XCTAssertEqual(index.longestPrefix(tokens: Array(tokens.prefix(count)), maximumCount: count + 1),
        .init(id: id(1), tokenCount: count))
      var changed = tokens
      changed[count - 1] = -7
      let expected: PrefixTokenIndex.Match? = count == 1 ? nil
        : .init(id: id(1), tokenCount: count - 1)
      XCTAssertEqual(index.longestPrefix(tokens: changed, maximumCount: tokens.count), expected)
    }
    XCTAssertEqual(index.longestPrefix(tokens: tokens, maximumCount: tokens.count - 1),
      .init(id: id(1), tokenCount: 16_383), "Caller can leave one token for logits.")
  }

  func testPrefixInsertionRemovalAndCompressionKeepLiveRepresentatives() {
    let index = PrefixTokenIndex()
    var oracle = Oracle()
    let histories = [[10, 20, 30, 40, 50], [10, 20, 99, 40], [10, 20],
      [10], [10, 20, 30], [10, 20, 30, 40, 80], [7, 8, 9]]
    let queries = histories + [[10, 20, 30, -1], [10, 20, 99, -1], [10, -1], [7, 8, -1]]
    for (offset, tokens) in histories.enumerated() {
      index.insert(tokens: tokens, id: id(offset + 1))
      oracle.insert(tokens, id: id(offset + 1))
      for query in queries {
        for cap in 0...query.count { assertMatch(index, oracle: oracle, tokens: query, maximumCount: cap) }
      }
    }
    for entry in [4, 3, 5, 6, 2, 7, 1] {
      index.remove(id: id(entry))
      oracle.entries.removeValue(forKey: id(entry))
      for query in queries {
        for cap in 0...query.count { assertMatch(index, oracle: oracle, tokens: query, maximumCount: cap) }
      }
    }
    XCTAssertNil(index.longestPrefix(tokens: [10, 20, 30], maximumCount: 3))
  }

  func testDuplicateTokensPreferLatestAndReplacingIDRemovesOldHistory() {
    let index = PrefixTokenIndex()
    let tokens = [1, 2, 3, 4]
    index.insert(tokens: tokens, id: id(1))
    index.insert(tokens: tokens, id: id(2))
    XCTAssertEqual(index.longestPrefix(tokens: tokens, maximumCount: 4),
      .init(id: id(2), tokenCount: 4))
    index.remove(id: id(2))
    XCTAssertEqual(index.longestPrefix(tokens: tokens, maximumCount: 4),
      .init(id: id(1), tokenCount: 4))
    index.insert(tokens: tokens, id: id(2))
    index.insert(tokens: [1, 2, 3, 9, 10], id: id(1))
    XCTAssertEqual(index.longestPrefix(tokens: tokens, maximumCount: 4),
      .init(id: id(2), tokenCount: 4))
    XCTAssertEqual(index.longestPrefix(tokens: tokens, maximumCount: 3),
      .init(id: id(1), tokenCount: 3), "Recency applies to equal matched lengths.")
    index.remove(id: id(2))
    XCTAssertEqual(index.longestPrefix(tokens: tokens, maximumCount: 4),
      .init(id: id(1), tokenCount: 3), "The replacement must not leave the old fourth token indexed.")
    index.insert(tokens: [99], id: id(1))
    XCTAssertNil(index.longestPrefix(tokens: tokens, maximumCount: 4))
  }

  func testCallerMutationCannotChangeInsertedTokens() {
    let index = PrefixTokenIndex()
    var tokens = [1, 2, 3, 4]
    index.insert(tokens: tokens, id: id(1))
    tokens[1] = 99
    tokens.append(5)
    XCTAssertEqual(index.longestPrefix(tokens: [1, 2, 3, 4], maximumCount: 4),
      .init(id: id(1), tokenCount: 4))
    XCTAssertEqual(index.longestPrefix(tokens: tokens, maximumCount: tokens.count),
      .init(id: id(1), tokenCount: 1))
  }

  func testSeparateIndicesAndRemoveAllDoNotLeakHistories() {
    let first = PrefixTokenIndex(), second = PrefixTokenIndex()
    let tokens = Array(0..<256)
    for count in 1...tokens.count {
      first.insert(tokens: Array(tokens.prefix(count)), id: id(count))
    }
    second.insert(tokens: tokens, id: id(999))
    first.removeAll()
    XCTAssertNil(first.longestPrefix(tokens: tokens, maximumCount: 255))
    XCTAssertEqual(second.longestPrefix(tokens: tokens, maximumCount: 255),
      .init(id: id(999), tokenCount: 255))
    first.insert(tokens: [42, 43], id: id(1))
    first.remove(id: id(256))
    XCTAssertEqual(first.longestPrefix(tokens: [42, 43, 44], maximumCount: 3),
      .init(id: id(1), tokenCount: 2))
  }

  func testAllMatchesKeepShorterAndOlderEligibilityCandidates() {
    let index = PrefixTokenIndex()
    index.insert(tokens: [1, 2], id: id(1))
    index.insert(tokens: [1, 2, 3, 4, 5], id: id(2))
    index.insert(tokens: [1, 2, 9, 10], id: id(3))
    index.insert(tokens: [1, 2, 3, 4, 5], id: id(4))
    XCTAssertEqual(index.matches(tokens: [1, 2, 3, 4, 99], maximumCount: 5), [
      .init(id: id(4), tokenCount: 4), .init(id: id(2), tokenCount: 4),
      .init(id: id(3), tokenCount: 2), .init(id: id(1), tokenCount: 2),
    ])
    XCTAssertEqual(index.matches(tokens: [1, 2, 3], maximumCount: 1), [
      .init(id: id(4), tokenCount: 1), .init(id: id(3), tokenCount: 1),
      .init(id: id(2), tokenCount: 1), .init(id: id(1), tokenCount: 1),
    ])
    index.remove(id: id(4))
    XCTAssertEqual(index.matches(tokens: [1, 2, 3, 4, 99], maximumCount: 5).first,
      .init(id: id(2), tokenCount: 4))
    XCTAssertEqual(index.matches(tokens: [1, 2], maximumCount: 2).map(\.id),
      [id(3), id(2), id(1)], "An endpoint query includes live descendant histories.")
    XCTAssertTrue(index.matches(tokens: [99], maximumCount: 1).isEmpty)
  }

  func testDeterministicInterleavedCorpusAgainstExhaustiveLCPOracle() {
    let index = PrefixTokenIndex()
    var oracle = Oracle(), generator = Generator()
    let trunk = (0..<16_384).map { ($0 * 17 + 3) % 211 }
    let lengths = [1, 2, 3, 31, 32, 33, 63, 64, 65, 127, 128, 129,
      511, 512, 513, 1024, 4096, 8192, 16_384]
    for step in 0..<192 {
      let entryID = id(generator.next(32) + 1)
      var tokens = Array(trunk.prefix(lengths[generator.next(lengths.count)]))
      if step % 3 != 0 { tokens[generator.next(tokens.count)] = 1000 + step }
      if step % 7 == 0 {
        index.remove(id: entryID)
        oracle.entries.removeValue(forKey: entryID)
      } else {
        index.insert(tokens: tokens, id: entryID)
        oracle.insert(tokens, id: entryID)
      }
      let cap = generator.next(tokens.count + 2)
      assertMatch(index, oracle: oracle, tokens: tokens, maximumCount: cap)
      assertMatch(index, oracle: oracle, tokens: tokens, maximumCount: tokens.count - 1)
      assertMatch(index, oracle: oracle, tokens: Array(trunk.prefix(tokens.count)), maximumCount: tokens.count)
      let short = Array(tokens.prefix(min(17, tokens.count))) + [-1000 - step]
      assertMatch(index, oracle: oracle, tokens: short, maximumCount: short.count)
      if step % 11 == 0 {
        for stored in oracle.entries.values {
          assertMatch(index, oracle: oracle, tokens: stored.tokens, maximumCount: stored.tokens.count)
        }
      }
    }
    for entry in 1...32 {
      index.remove(id: id(entry))
      oracle.entries.removeValue(forKey: id(entry))
      assertMatch(index, oracle: oracle, tokens: trunk, maximumCount: trunk.count)
    }
    XCTAssertNil(index.longestPrefix(tokens: trunk, maximumCount: trunk.count))
  }
}
