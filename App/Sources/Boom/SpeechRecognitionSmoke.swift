import BoomCore
import Foundation

/// Explicit public-audio diagnostic; no workspace, Keychain, microphone or
/// transcript plaintext is exported. Uses the production recognition lifecycle.
@MainActor enum SpeechRecognitionSmoke {
  static func run(arguments: [String]) async throws {
    func argument(_ name: String) throws -> String {
      guard arguments.filter({ $0 == name }).count == 1,
        let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
        throw BoomError.invalid("Use --speech-recovery-smoke --audio-file ABSOLUTE_PUBLIC_AUDIO --evidence NEW_ABSOLUTE_DIRECTORY.")
      }
      return arguments[index + 1]
    }
    let path = try argument("--audio-file"), destination = try argument("--evidence")
    guard path.hasPrefix("/"), destination.hasPrefix("/"),
      !FileManager.default.fileExists(atPath: destination) else {
      throw BoomError.invalid("Speech qualification requires public audio and a fresh evidence directory.")
    }
    let evidence = URL(fileURLWithPath: destination)
    try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: false)
    let voice = VoiceInput(), audio = URL(fileURLWithPath: path)
    var observations: [[String: Any]] = []
    func save(_ status: String, error: String? = nil) throws {
      let receipt: [String: Any] = ["status": status, "observations": observations,
        "sourceInventorySHA256": Bundle.main.infoDictionary?["BoomSourceSHA256"] ?? "unavailable",
        "pid": ProcessInfo.processInfo.processIdentifier, "publicFixtureOnly": true,
        "keychainLookups": VaultSession.shared.lookupCount, "error": error as Any? ?? NSNull()]
      try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
        .write(to: evidence.appendingPathComponent("receipt.json"), options: .atomic)
    }
    do {
      for attempt in 0..<3 {
        let began = ContinuousClock().now
        let result = try await voice.transcribeAttachment(audio, flag: CancellationFlag()) { _, _ in }
        guard !result.text.isEmpty else { throw BoomError.invalid("Public speech fixture produced no words.") }
        observations.append(["action": "recognize", "attempt": attempt,
          "textSHA256": Digest.sha256(result.text), "characters": result.text.count,
          "seconds": seconds(began.duration(to: ContinuousClock().now))])
        if attempt == 0 {
          let flag = CancellationFlag()
          let canceller = Task { try? await Task.sleep(for: .milliseconds(100)); flag.cancel() }
          let began = ContinuousClock().now
          do {
            _ = try await voice.transcribeAttachment(audio, flag: flag) { _, _ in }
            canceller.cancel(); await canceller.value
            throw BoomError.invalid("Speech completed before the cancellation check could run.")
          } catch is CancellationError {
            canceller.cancel(); await canceller.value
            observations.append(["action": "cancel", "seconds": seconds(began.duration(to: ContinuousClock().now))])
          } catch { canceller.cancel(); await canceller.value; throw error }
        }
      }
      try save("passed")
    } catch { try save("failed", error: error.localizedDescription); throw error }
  }
  private static func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
  }
}
