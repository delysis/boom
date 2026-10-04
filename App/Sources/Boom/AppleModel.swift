import BoomCore
import Foundation
import FoundationModels

/// Uses only the public, on-device Foundation Models API. Each operation owns
/// its session, so a cancelled completion cannot contaminate a later request.
enum AppleModel {
  static var isAvailable: Bool {
    if #available(macOS 26.0, *) { return SystemLanguageModel.default.isAvailable }
    return false
  }

  static var availabilityMessage: String {
    if #available(macOS 26.0, *) {
      switch SystemLanguageModel.default.availability {
      case .available: return "Apple Foundation Model ready on this Mac"
      case .unavailable(.deviceNotEligible): return "Apple Foundation Model: this Mac is not eligible"
      case .unavailable(.appleIntelligenceNotEnabled):
        return "Apple Foundation Model: enable Apple Intelligence in System Settings"
      case .unavailable(.modelNotReady):
        return "Apple's system model is not ready. macOS may still be downloading it; check Siri in System Settings and keep the Mac on power and Wi-Fi."
      @unknown default: return "Apple Foundation Model is unavailable"
      }
    }
    return "Apple Foundation Models requires macOS 26 or newer; this Mac needs a local Gemma model"
  }

  static func respond(to prompt: String, instructions: String = "") async throws -> String {
    guard #available(macOS 26.0, *), SystemLanguageModel.default.isAvailable else {
      throw BoomError.unavailable(availabilityMessage)
    }
    try Task.checkCancellation()
    let session = instructions.isEmpty
      ? LanguageModelSession() : LanguageModelSession(instructions: instructions)
    let response = try await session.respond(to: prompt)
    try Task.checkCancellation()
    guard !response.content.isEmpty else { throw BoomError.unavailable("Apple returned no text.") }
    return response.content
  }

  static func conversation(
    history: [ChatMessage], context: String, request: String
  ) throws -> String {
    let prior = history.filter { $0.state == .complete }
      .map { "\($0.role.rawValue.uppercased()): \($0.text)" }
      .joined(separator: "\n\n")
    let prompt = [prior, context, request].filter { !$0.isEmpty }.joined(separator: "\n\n")
    guard prompt.utf8.count <= 16_384 else {
      throw BoomError.budget("Apple model context exceeds Bloom's 16 KiB text bound; use Gemma or shorten the request.")
    }
    return prompt
  }

  /// Actual system-model calls for a CLI gate on Macs where Apple Intelligence
  /// has finished preparing. Availability alone is not a generation test.
  static func smoke() async throws {
    guard isAvailable else { throw BoomError.unavailable(availabilityMessage) }
    let chat = try await respond(to: "What color is a clear daytime sky? Answer briefly.")
    print("Apple chat: \(chat)")
  }
}
