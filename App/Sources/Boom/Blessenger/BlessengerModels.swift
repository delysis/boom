import BoomCore
import CoreML
import Foundation
import MLX
import Qwen3TTS

/// These are signed, pinned public *data* packages. Acquisition is an explicit
/// setup action. Calling and speaking only use verified local files.
struct BlessengerModelPackage: Codable, Sendable, Identifiable {
  enum Kind: String, Codable, Sendable { case qwen, mtp, turn }
  let id: Kind
  let repository: String
  let revision: String
  let files: [ModelFile]
  var identity: String { repository + "@" + revision }
  func requirements() throws -> CheckpointRequirements {
    try ProductCore.call(["op": "blessenger", "request": ["op": "asset_requirements", "package": ProductCore.object(self)]])
  }
  static func catalog() throws -> [Self] {
    guard let url = Bundle.module.url(forResource: "BlessengerVoiceModels", withExtension: "json") else {
      throw BoomError.unavailable("The signed voice model catalog is missing.")
    }
    let packages = try JSONDecoder().decode([Self].self, from: RegularFile(url, limit: 262_144).data())
    guard Set(packages.map(\.id)).count == packages.count, packages.count == 3 else {
      throw BoomError.invalid("Duplicate or missing voice model identities.")
    }
    for package in packages { _ = try package.requirements() }
    return packages
  }
  static func package(_ kind: Kind) throws -> Self {
    guard let value = try catalog().first(where: { $0.id == kind }) else { throw BoomError.unavailable("Missing voice package.") }
    return value
  }
  func local() throws -> URL {
    _ = try requirements()
    for hub in HuggingFaceCache.hubs {
      let root = ModelPacks.snapshot(repository: repository, revision: revision, hub: hub)
      if FileManager.default.fileExists(atPath: root.path) { try verify(root); return root }
    }
    throw BoomError.unavailable("Install the \(id.rawValue) model in Settings before using this route.")
  }
  func verify(_ directory: URL) throws {
    _ = try requirements()
    try ModelPacks.verifyPublicFiles(directory, files: files)
    // Core ML recursively loads a compiled program. No unlisted sidecar or
    // symlink may smuggle another graph into the pinned program directory.
    if id == .turn {
      let root = directory.appendingPathComponent("smart_turn.mlmodelc", isDirectory: true)
      let expected = Set(files.filter { $0.path.hasPrefix("smart_turn.mlmodelc/") }.map { String($0.path.dropFirst(20)) })
      guard let children = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
        throw BoomError.invalid("The compiled turn model is missing.")
      }
      var seen = Set<String>()
      for case let url as URL in children {
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard info.isSymbolicLink != true else { throw BoomError.invalid("A compiled turn model contains a symbolic link.") }
        if info.isRegularFile == true { seen.insert(String(url.path.dropFirst(root.path.count + 1))) }
      }
      guard seen == expected else { throw BoomError.invalid("The turn model contains unlisted or missing data files.") }
    }
  }
  func install(flag: CancellationFlag, progress: @escaping @Sendable (String) -> Void) async throws -> URL {
    try await ModelPacks.installFiles(repository: repository, revision: revision, files: files,
      requirements: requirements(), label: id.rawValue, flag: flag, progress: progress)
  }
}

/// One response owns a Qwen pipeline until the awaited method returns. Its
/// callback is backpressured by the same native PCM queue as Apple speech.
actor BlessengerQwenSpeech {
  private var pipeline: Qwen3TTSPipeline?
  private var weightLease: ModelWeightLease?
  private var modelIdentity: String?
  private var occupied = false
  func prepare() async throws -> String {
    guard !occupied else { throw BoomError.unavailable("Speech is still generating.") }
    let specification = try BlessengerModelPackage.package(.qwen)
    if pipeline != nil, modelIdentity == specification.identity { return specification.identity }
    let directory = try await detachedWork { try specification.local() }
    let requirements = try specification.requirements()
    await GenerationCoordinator.shared.enter()
    do {
      try Task.checkCancellation()
      let lease = try ModelWeightLease(bytes: requirements.weightBytes)
      let value = try await InferenceExecutor.shared.perform { _ in
        defer { Stream.defaultStream(.gpu).synchronize() }
        return try Qwen3TTSPipeline(modelPath: directory,
          configuration: Qwen3TTSPipelineConfiguration(applyRuntimeQuantization: false, defaultMaxTokens: 512))
      }
      try await detachedWork { try specification.verify(directory) }
      guard value.supportsVoiceDesign else { throw BoomError.invalid("The pinned speech model is not VoiceDesign.") }
      try ModelResidency.check(); pipeline = value; weightLease = lease; modelIdentity = specification.identity
      await GenerationCoordinator.shared.leave()
      return specification.identity
    } catch { await GenerationCoordinator.shared.leave(); throw error }
  }
  func synthesize(_ text: String, voice: BlessengerSpeechVoice, seed: UInt64, flag: CancellationFlag,
    observe: @escaping @Sendable (String, Double) -> Void,
    receive: @escaping @Sendable (BlessengerPCM) async throws -> Void) async throws {
    guard !occupied, let pipeline, modelIdentity != nil else { throw BoomError.unavailable("Prepare the local Qwen voice before speaking.") }
    guard voice.provider == .qwen, voice.identifier == modelIdentity else { throw BoomError.stale("The captured speech model is no longer the prepared provider.") }
    occupied = true; defer { occupied = false }
    // Loading is serialized with model admission. Independent LM/TTS generation
    // overlaps, but both obey the process resource policy and retain their joins.
    let ticket = try await GenerationCoordinator.shared.beginSpeech(flag: flag)
    do {
    try await InferenceExecutor.shared.perform { _ in
      try await pipeline.generateOwnedVoiceDesign(text: text, voiceDescription: voice.description,
        seed: seed, checkCancellation: { try flag.check(); try ModelResidency.check() },
        observe: observe) { samples, _ in
          // A final codec flush can contain several packets; the native ingress
          // remains bounded without discarding or repairing any sample.
          for start in stride(from: 0, to: samples.count, by: 24_000) {
            try flag.check()
            let packet = try BlessengerPCM(samples: Array(samples[start..<min(start + 24_000, samples.count)]), rate: 24_000)
            try await receive(packet)
          }
        }
    }
    await GenerationCoordinator.shared.endSpeech(ticket)
    } catch { await GenerationCoordinator.shared.endSpeech(ticket); throw error }
  }
  func unload() throws {
    guard !occupied else { throw BoomError.unavailable("Join speech before unloading its model.") }
    pipeline = nil; weightLease = nil; modelIdentity = nil
  }
}

/// Classifies the current audio window, not a transcript or a silence timer.
/// The bundled Core ML graph includes normalization and feature extraction.
actor BlessengerTurnClassifier {
  private var model: MLModel?
  private(set) var identity: String?
  static let samples = 128_000
  static func window(_ samples: [Float]) throws -> [Float] {
    guard samples.allSatisfy(\.isFinite) else { throw BoomError.invalid("Caller audio contains nonfinite samples.") }
    let tail = samples.suffix(Self.samples)
    return Array(repeating: 0, count: Self.samples - tail.count) + tail
  }
  func prepare() async throws {
    if model != nil { return }
    let specification = try BlessengerModelPackage.package(.turn)
    let directory = try await detachedWork { try specification.local() }
    let configuration = MLModelConfiguration(); configuration.computeUnits = .cpuAndNeuralEngine
    let loaded = try await MLModel.load(contentsOf: directory.appendingPathComponent("smart_turn.mlmodelc"), configuration: configuration)
    guard loaded.modelDescription.inputDescriptionsByName["audio"]?.multiArrayConstraint?.shape.map(\.intValue) == [1, Self.samples],
      loaded.modelDescription.outputDescriptionsByName["probability"] != nil else {
      throw BoomError.invalid("The semantic turn model has an incompatible input contract.")
    }
    try await detachedWork { try specification.verify(directory) }
    model = loaded; identity = specification.identity
  }
  func probability(_ samples: [Float]) async throws -> Float {
    guard let model else { throw BoomError.unavailable("The semantic turn model is not prepared.") }
    let window = try Self.window(samples)
    let array = try MLMultiArray(shape: [1, NSNumber(value: Self.samples)], dataType: .float32)
    for i in window.indices { array[i] = NSNumber(value: window[i]) }
    let output = try await model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio": array]))
    guard let result = output.featureValue(for: "probability")?.multiArrayValue, result.count == 1 else {
      throw BoomError.invalid("The turn classifier returned an invalid output.")
    }
    let probability = result[0].floatValue
    guard probability.isFinite, (0...1).contains(probability) else { throw BoomError.invalid("The turn classifier returned an invalid probability.") }
    return probability
  }
}
