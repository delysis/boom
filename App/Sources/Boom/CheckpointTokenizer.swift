import BoomCore
import Foundation
import Hub
import MLXHuggingFace
import MLXLMCommon
import Tokenizers

/// Use the checkpoint's decoder, without Transformers' extra English cleanup.
/// In particular, `. . .`, spaces before punctuation and authored apostrophes
/// must survive decoding. The override is in memory; admitted files stay intact.
struct CheckpointTokenizerLoader: MLXLMCommon.TokenizerLoader {
  func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
    let source = LanguageModelConfigurationFromHub(modelFolder: directory)
    guard let configuration = try await source.tokenizerConfig,
      var values = configuration.dictionary() else {
      throw BoomError.invalid("Invalid checkpoint tokenizer configuration.")
    }
    values["clean_up_tokenization_spaces"] = Config(false)
    let data = try await source.tokenizerData
    let upstream = try AutoTokenizer.from(tokenizerConfig: Config(values), tokenizerData: data)
    return #adaptHuggingFaceTokenizer(upstream)
  }
}
