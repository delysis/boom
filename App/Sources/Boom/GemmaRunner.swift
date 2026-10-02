import CoreML
import CoreMLLLM
import CryptoKit
import Darwin
import Foundation
import BoomCore

/// There is one queue and one loaded model. Queue completion, not Task.cancel(),
/// releases the mutable runtime. Even a cancelled prefill is joined before reuse.
final class GemmaRunner: @unchecked Sendable {
  let identity: ModelIdentity
  let supportsImages: Bool
  let supportsAudio: Bool
  let audioSeconds: Double
  private let queue = DispatchQueue(label: "com.delysis.boom.gemma", qos: .userInitiated)
  private var followedMemory: (String, BoomKVSnapshot)?
  private let model: CoreMLLLM
  private init(model: CoreMLLLM, identity: ModelIdentity) {
    self.model = model
    self.identity = identity
    supportsImages = model.supportsVision
    supportsAudio = model.supportsAudio
    audioSeconds = model.maxAudioDuration
  }
  private static func hardwareIdentity() -> String {
    var count = 0
    guard sysctlbyname("hw.model", nil, &count, nil, 0) == 0, count > 0, count < 1024 else {
      return "unknown-hardware"
    }
    var bytes = [CChar](repeating: 0, count: count)
    guard sysctlbyname("hw.model", &bytes, &count, nil, 0) == 0 else { return "unknown-hardware" }
    return String(cString: bytes)
  }
  private static func buildIdentity() throws -> String {
    let keys = ["BoomSourceSHA256", "BoomDependencyLockSHA256"]
    let values = try keys.map { key -> String in
      guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
        value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
      else {
        throw BoomError.unavailable(
          "This executable has no recorded native build identity. Build the application bundle with scripts/build-macos.sh before loading models or persistent caches."
        )
      }
      return value
    }
    return values.joined(separator: ":")
  }
  static func load(directory: URL, manifestDigest: String) async throws -> GemmaRunner {
    let build = try buildIdentity()
    let model = try await CoreMLLLM.boomLoad(from: directory)
    return GemmaRunner(
      model: model,
      identity: ModelIdentity(
        manifestDigest: manifestDigest,
        runtimeRevision: "18a9b5fd3d7e1f1f5d182533c94d311a7e649f7c;boom="
          + BoomBuildContract.sourceFingerprint + ";build=" + build + ";os="
          + ProcessInfo.processInfo.operatingSystemVersionString + ";hardware=" + hardwareIdentity()
          + ";decode=cpuAndNeuralEngine", promptVersion: GemmaPrompt.version,
        contextLength: model.contextLength))
  }
  func run(
    prompt: String, restore: BoomKVSnapshot? = nil, maxTokens: Int, flag: CancellationFlag,
    onText: @escaping @Sendable (String) -> Void
  ) async throws -> BoomRunResult {
    try await withTaskCancellationHandler(
      operation: {
        try await withCheckedThrowingContinuation { continuation in
          queue.async {
            do {
              try flag.check()
              continuation.resume(
                returning: try self.model.boomRun(
                  prompt: prompt, identity: self.identity.key, restoring: restore,
                  maxTokens: maxTokens, cancelled: { flag.isCancelled }, onText: onText))
            } catch { continuation.resume(throwing: error) }
          }
        }
      }, onCancel: { flag.cancel() })
  }
  func describe(
    image: CGImage? = nil, audio: [Float]? = nil, flag: CancellationFlag,
    onText: @escaping @Sendable (String) -> Void
  ) async throws -> BoomRunResult {
    try await withTaskCancellationHandler(
      operation: {
        try await withCheckedThrowingContinuation { continuation in
          queue.async {
            do {
              try flag.check()
              continuation.resume(
                returning: try self.model.boomDescribe(
                  image: image, audio: audio, cancelled: { flag.isCancelled }, onText: onText))
            } catch { continuation.resume(throwing: error) }
          }
        }
      }, onCancel: { flag.cancel() })
  }
  func join() async {
    await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
  }
}

struct StoredPersonaCache: Codable {
  let descriptor: CacheDescriptor
  let payload: Data
}
struct StoredFollowCache: Codable {
  let prefix: String
  let cache: StoredPersonaCache
}
struct CompletionResult: Sendable {
  let output: BoomRunResult
  let window: CompletionWindow
  var cachedTokens: Int { output.cachedTokens }
}
struct FittedConversation: Sendable {
  let history: [ChatMessage]
  let context: String
  let omittedHistoryCount: Int
  let omittedContextCharacters: Int
}
extension GemmaRunner {
  /// Use the loaded tokenizer and compiled graph limit. Historic messages are
  /// dropped oldest first only if even a middle excerpt of current sources
  /// cannot fit. The current request and edit authority are never truncated.
  func fitConversation(
    prefixes: [String?], history: [ChatMessage], instructions: String,
    context: String, request: String, maxOutputTokens: Int, flag: CancellationFlag
  ) async throws -> FittedConversation {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        do {
          try flag.check()
          let capacity = self.identity.contextLength - maxOutputTokens
          guard capacity > 0 else { throw BoomError.budget("The model has no room for a reply.") }
          let checkedPrefixes: [String?] = prefixes.isEmpty ? [nil] : prefixes
          func fits(_ history: [ChatMessage], _ suppliedContext: String) -> Bool {
            let joined = [instructions, suppliedContext, request]
              .filter { !$0.isEmpty }.joined(separator: "\n\n")
            return checkedPrefixes.allSatisfy { prefix in
              let prompt = GemmaPrompt.conversation(
                prefix: prefix, history: history, request: joined)
              return self.model.boomEncode(prompt).count <= capacity
            }
          }
          for dropped in 0...history.count {
            try flag.check()
            let kept = Array(history.dropFirst(dropped))
            if fits(kept, context) {
              continuation.resume(returning: FittedConversation(
                history: kept, context: context, omittedHistoryCount: dropped,
                omittedContextCharacters: 0))
              return
            }
            guard !context.isEmpty, fits(kept, ContextExcerpt.middle(context, keeping: 0))
            else { continue }
            var low = 0
            var high = context.count
            while low < high {
              try flag.check()
              let middle = low + (high - low + 1) / 2
              if fits(kept, ContextExcerpt.middle(context, keeping: middle)) {
                low = middle
              } else {
                high = middle - 1
              }
            }
            let excerpt = ContextExcerpt.middle(context, keeping: low)
            continuation.resume(returning: FittedConversation(
              history: kept, context: excerpt, omittedHistoryCount: dropped,
              omittedContextCharacters: context.count - low))
            return
          }
          throw BoomError.budget(
            "The current request and selected persona exceed this model's context. The request was retained; shorten it or select another model.")
        } catch { continuation.resume(throwing: error) }
      }
    }
  }
}
extension GemmaRunner {
  /// One encrypted disk slot plus one immutable memory snapshot. Switching the
  /// followed-document set replaces a VALID derived cache; corrupt records are
  /// retained and require the explicit Clear Autocomplete Cache action.
  func complete(
    document: DocumentSnapshot, caret: Int, context: ContextPlan, vault: Vault,
    flag: CancellationFlag, onText: @escaping @Sendable (String) -> Void
  ) async throws -> CompletionResult {
    return try await withTaskCancellationHandler(
      operation: {
        try await withCheckedThrowingContinuation { continuation in
          queue.async {
            do {
              try flag.check()
              var before = 2048
              let after = 512
              let totalSourceCharacters = context.documents.reduce(0) { $0 + $1.text.count }
              var sourceCharacters: Int? = context.documents.isEmpty
                ? nil : totalSourceCharacters
              func promptFor(_ draftCharacters: Int, _ sourceCharacters: Int?) throws -> String {
                try GemmaPrompt.completion(
                  document: document, caretUTF16: caret, context: context,
                  prefixCharacters: draftCharacters, suffixCharacters: after,
                  sourceBodyCharacters: sourceCharacters)
              }
              func fits(_ prompt: String) -> Bool {
                self.model.boomEncode(prompt).count + 64 <= self.identity.contextLength
              }
              var prompt = try promptFor(before, sourceCharacters)
              if !fits(prompt), totalSourceCharacters > 0 {
                var low = 0
                var high = totalSourceCharacters
                while low < high {
                  try flag.check()
                  let middle = low + (high - low + 1) / 2
                  if fits(try promptFor(before, middle)) { low = middle }
                  else { high = middle - 1 }
                }
                sourceCharacters = low
                prompt = try promptFor(before, sourceCharacters)
              }
              while !fits(prompt) {
                try flag.check()
                guard before > 1 else {
                  throw BoomError.budget(
                    "Source identities and the text at the caret exceed this model's context. Unlink a reference or select a larger model."
                  )
                }
                before = max(1, before / 2)
                prompt = try promptFor(before, sourceCharacters)
              }
              let prefix = GemmaPrompt.followedPrefix(
                context, bodyCharacters: sourceCharacters)
              let window = try CompletionWindow(
                document: document, caretUTF16: caret, prefixCharacters: before,
                suffixCharacters: after)
              var restore: BoomKVSnapshot?
              if let prefix {
                let key = Digest.sha256(self.identity.key + "\n" + prefix)
                if let memory = self.followedMemory, memory.0 == key {
                  restore = memory.1
                } else {
                  if vault.exists(.followCache, Vault.followCacheID) {
                    let disk: StoredFollowCache = try vault.decode(
                      StoredFollowCache.self, kind: .followCache, id: Vault.followCacheID,
                      limit: 1_100_000_000)
                    // Authenticate and validate an older slot before replacement.
                    // A new prefix/model is normal; malformed cache data is not.
                    try disk.cache.descriptor.validate(
                      model: disk.cache.descriptor.model, prefix: disk.prefix,
                      payload: disk.cache.payload)
                    if disk.prefix == prefix, disk.cache.descriptor.model == self.identity {
                      let snapshot = try PropertyListDecoder().decode(
                        BoomKVSnapshot.self, from: disk.cache.payload)
                      guard snapshot.position == disk.cache.descriptor.tokenCount,
                        snapshot.identity == self.identity.key
                      else {
                        throw BoomError.invalid(
                          "Followed-document cache metadata disagrees with native state.")
                      }
                      restore = snapshot
                    }
                  }
                  if restore == nil {
                    let result = try self.model.boomRun(
                      prompt: prefix, identity: self.identity.key, maxTokens: 0,
                      cancelled: { flag.isCancelled }, onText: { _ in })
                    guard let snapshot = result.snapshot else {
                      throw BoomError.invalid("No native followed-document snapshot was returned.")
                    }
                    let encoder = PropertyListEncoder()
                    encoder.outputFormat = .binary
                    let payload = try encoder.encode(snapshot)
                    let descriptor = CacheDescriptor(
                      model: self.identity, prefixDigest: Digest.sha256(prefix), payload: payload,
                      tokenCount: snapshot.position)
                    try flag.check()
                    try vault.encode(
                      StoredFollowCache(
                        prefix: prefix,
                        cache: StoredPersonaCache(descriptor: descriptor, payload: payload)),
                      kind: .followCache, id: Vault.followCacheID)
                    let written: StoredFollowCache = try vault.decode(
                      StoredFollowCache.self, kind: .followCache, id: Vault.followCacheID,
                      limit: 1_100_000_000)
                    try written.cache.descriptor.validate(
                      model: self.identity, prefix: prefix, payload: written.cache.payload)
                    restore = snapshot
                  }
                  if let restore { self.followedMemory = (key, restore) }
                }
              }
              try flag.check()
              let output = try self.model.boomRun(
                prompt: prompt, identity: self.identity.key, restoring: restore, maxTokens: 64,
                cancelled: { flag.isCancelled }, onText: onText)
              continuation.resume(returning: CompletionResult(output: output, window: window))
            } catch { continuation.resume(throwing: error) }
          }
        }
      }, onCancel: { flag.cancel() })
  }
  func clearFollowCache(vault: Vault) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      queue.async {
        do {
          try vault.remove(.followCache, id: Vault.followCacheID)
          self.followedMemory = nil
          continuation.resume()
        } catch { continuation.resume(throwing: error) }
      }
    }
  }
  func makePersona(
    slug: String, title: String, messages: [ChatMessage], vault: Vault, flag: CancellationFlag
  ) async throws -> Persona {
    let prefix = try GemmaPrompt.prefix(messages)
    let result = try await run(prompt: prefix, maxTokens: 0, flag: flag, onText: { _ in })
    try flag.check()
    guard let snapshot = result.snapshot else {
      throw BoomError.invalid("The runtime did not return native KV tensors.")
    }
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    let payload = try encoder.encode(snapshot)
    let id = UUID()
    let descriptor = CacheDescriptor(
      model: identity, prefixDigest: Digest.sha256(prefix), payload: payload,
      tokenCount: snapshot.position)
    try vault.encode(
      StoredPersonaCache(descriptor: descriptor, payload: payload), kind: .personaCache, id: id)
    // Re-open/authenticate the actual stored bytes before publishing a Ready persona.
    let verified: StoredPersonaCache = try vault.decode(
      StoredPersonaCache.self, kind: .personaCache, id: id, limit: 1_100_000_000)
    try verified.descriptor.validate(model: identity, prefix: prefix, payload: verified.payload)
    try flag.check()
    return try Persona(
      slug: slug, title: title, messages: messages, prefixDigest: Digest.sha256(prefix),
      model: identity, cacheID: id)
  }
  func restorePersona(_ persona: Persona, vault: Vault) throws -> (String, BoomKVSnapshot) {
    let prefix = try GemmaPrompt.prefix(persona.messages)
    guard persona.model == identity, persona.prefixDigest == Digest.sha256(prefix) else {
      throw BoomError.stale("Persona \(persona.title) needs rebuilding for this model.")
    }
    let stored: StoredPersonaCache = try vault.decode(
      StoredPersonaCache.self, kind: .personaCache, id: persona.cacheID, limit: 1_100_000_000)
    try stored.descriptor.validate(model: identity, prefix: prefix, payload: stored.payload)
    let state = try PropertyListDecoder().decode(BoomKVSnapshot.self, from: stored.payload)
    guard state.identity == identity.key, state.position == stored.descriptor.tokenCount else {
      throw BoomError.invalid("Cache token identity mismatch.")
    }
    return (prefix, state)
  }
}
