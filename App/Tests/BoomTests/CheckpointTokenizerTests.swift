import Foundation
import Hub
import Tokenizers
import XCTest
@testable import Boom

final class CheckpointTokenizerTests: XCTestCase {
  func testRawDecodingPreservesPunctuationAndBinaryDistinctUnicodeWithoutChangingFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-tokenizer-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = Data(#"{"tokenizer_class":"GemmaTokenizer","bos_token":"<bos>","eos_token":"<eos>","clean_up_tokenization_spaces":true}"#.utf8)
    let description = Data(#"{"model":{"type":"BPE","vocab":{"▁":0,".":1,"?":2,",":3,"é":4,"e\u0301":5,"😺":6,"\n":7,"<bos>":8,"<eos>":9},"merges":[]},"added_tokens":[{"id":8,"content":"<bos>","special":true},{"id":9,"content":"<eos>","special":true}],"decoder":{"type":"Sequence","decoders":[{"type":"Replace","pattern":{"String":"▁"},"content":" "},{"type":"Fuse"}]}}"#.utf8)
    try configuration.write(to: root.appendingPathComponent("tokenizer_config.json"))
    try description.write(to: root.appendingPathComponent("tokenizer.json"))
    let raw = try await CheckpointTokenizerLoader().load(from: root)
    let defaultTokenizer = try await AutoTokenizer.from(modelFolder: root)
    let punctuation = [1, 0, 1, 0, 1, 0, 2, 0, 3]
    XCTAssertEqual(defaultTokenizer.decode(tokens: punctuation), "...?,")
    XCTAssertEqual(raw.decode(tokenIds: punctuation), ". . . ? ,")
    XCTAssertEqual(Array(raw.decode(tokenIds: [4, 0, 5, 0, 6, 7]).utf8), Array("é e\u{301} 😺\n".utf8))
    // This tiny vocabulary covers decoding, not UTF-8 byte fallback encoding.
    for value in [".", "?", ","] {
      XCTAssertEqual(raw.encode(text: value, addSpecialTokens: false), defaultTokenizer.encode(text: value, addSpecialTokens: false))
    }
    XCTAssertEqual(raw.eosTokenId, 9)
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("tokenizer_config.json")), configuration)
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("tokenizer.json")), description)
  }
}
