import BoomCore
import Foundation

struct BlessengerCatalog: Codable, Sendable {
  struct Entry: Codable, Sendable {
    let id: UUID
    let sourceID: String
    let name: String
    let handle: String
    let instructions: String
    let promptSHA256: String
    let portraitCell: Int
  }
  let sourceRevision: String
  let sourceSHA256: String
  let entries: [Entry]
  static func load() throws -> Self {
    guard let path = Bundle.module.url(forResource: "BlessengerContacts", withExtension: "json") else {
      throw BoomError.unavailable("The signed Contact catalog is missing.")
    }
    let catalog = try JSONDecoder().decode(Self.self, from: RegularFile(path, limit: 262_144).data())
    guard catalog.sourceSHA256 == "09557b34bc9c85108ab7f901ca419fa50eb60283fb79519b6eeecccf8213ea64",
      catalog.entries.count == 14, Set(catalog.entries.map(\.id)).count == 14,
      Set(catalog.entries.map(\.handle)).count == 14,
      Set(catalog.entries.map(\.sourceID)).count == 14 else { throw BoomError.invalid("The built-in Contact catalog is inconsistent.") }
    for entry in catalog.entries {
      guard Digest.sha256(entry.instructions) == entry.promptSHA256,
        (0..<14).contains(entry.portraitCell) else { throw BoomError.invalid("A built-in Contact prompt or portrait identity changed.") }
      _ = try ProductCore.voice(VoiceDraft(id: entry.id, slug: entry.handle, name: entry.name, instructions: entry.instructions))
    }
    return catalog
  }
}
struct BlessengerPreparedTurn: Sendable {
  let chatID: UUID
  let draft: BlessengerDraft
  let history: ChatRecord?
  let contacts: [BlessengerContact]
  let profile: BlessengerProfile
  let sourceDigests: [SourceReference]
  let context: String
  let responseIDs: [UUID]
  let receipts: [ConsultationReceipt]
  let voices: [Voice?]
  let outputLimit: Int
  var caller: BlessengerCallerTurn? = nil
  var speech: BlessengerSpeechVoice? = nil
}

extension WorkspaceStore {
  func openBlessenger(catalog: BlessengerCatalog) throws -> WorkspaceState {
    guard vault.isProtected else { throw BoomError.denied("Blessenger requires encrypted storage.") }
    let fresh = !vault.exists(.workspace, Vault.workspaceID)
    try BlessengerInventory.validate(self, fresh: fresh)
    var state = try loadState()
    if fresh { state.blessenger = BlessengerState() }
    guard var product = state.blessenger else {
      throw BoomError.invalid("This is not a Blessenger workspace. No conversion was attempted.")
    }
    for entry in catalog.entries where !product.removedCatalog.contains(entry.id) {
      let candidate = try ProductCore.voice(VoiceDraft(id: entry.id, slug: entry.handle,
        name: entry.name, instructions: entry.instructions))
      if let existing = state.voices.first(where: { $0.id == entry.id }) {
        guard product.managedCatalog[entry.id] == existing.revision, existing.revision != candidate.revision else { continue }
        guard let index = state.chats.firstIndex(where: { $0.id == entry.id }) else {
          throw BoomError.invalid("A catalog-managed Contact lost its source conversation.")
        }
        state.voiceVersions.append(existing)
        state.voices.removeAll { $0.id == existing.id }
        state.chats[index].title = entry.name; state.chats[index].instructions = entry.instructions
      } else {
        guard !state.chats.contains(where: { $0.id == entry.id }), !state.voices.contains(where: { $0.slug == entry.handle }) else {
          throw BoomError.invalid("A built-in Contact collides with an existing conversation or handle.")
        }
        state.chats.append(ChatRecord(id: entry.id, title: entry.name, instructions: entry.instructions))
      }
      state.voices.append(candidate); product.managedCatalog[entry.id] = candidate.revision
    }
    // An interrupted attempt keeps its partial text and identity. It is never
    // automatically regenerated or spoken after relaunch.
    product.attempts = product.attempts.filter { _, attempt in
      state.chats.first(where: { $0.id == attempt.conversationID })?.messages
        .first(where: { $0.id == attempt.messageID })?.state == .pending
    }
    state.blessenger = product
    try saveState(state)
    blessengerRuntime = state
    return state
  }
  func blessengerSnapshot() throws -> WorkspaceState {
    guard let value = blessengerRuntime else { throw BoomError.unavailable("The private conversation store is closed.") }
    return value
  }
  /// No await in this transaction: validation, atomic record replacement and
  /// publication are serialized by the existing store actor. A write can fail
  /// after physical publication. Retire the runtime on any persistence failure:
  /// the next launch reconciles the actual durable record, never a guessed rollback.
  func blessengerTransaction<T: Sendable>(
    _ change: @Sendable (inout WorkspaceState, inout BlessengerState) throws -> T
  ) throws -> (WorkspaceState, T) {
    guard var next = blessengerRuntime, var product = next.blessenger else {
      throw BoomError.unavailable("The private conversation store is closed.")
    }
    let result = try change(&next, &product)
    guard product.generation < UInt64.max else { throw BoomError.invalid("Private state revision exhausted.") }
    product.generation += 1; next.blessenger = product
    do { try saveState(next) }
    catch { blessengerRuntime = nil; throw error }
    blessengerRuntime = next
    return (next, result)
  }
  func blessengerSelect(_ id: UUID?, template: Bool = false) throws -> WorkspaceState {
    try blessengerTransaction { state, product in
      if let id {
        guard state.chats.contains(where: { $0.id == id }), !template || state.voices.contains(where: { $0.id == id }) else {
          throw BoomError.stale("The selected conversation is no longer available.")
        }
        if !product.drafts.contains(where: { $0.id == id }) { product.drafts.append(BlessengerDraft(id: id)) }
      }
      state.selectedChat = id; product.selectedTemplate = template ? id : nil
    }.0
  }
  func blessengerSaveDraft(_ draft: BlessengerDraft, expectedVersion: UUID) throws -> WorkspaceState {
    _ = try BlessengerPolicy.validate(draft)
    return try blessengerTransaction { state, product in
      guard let index = product.drafts.firstIndex(where: { $0.id == draft.id }),
        product.drafts[index].version == expectedVersion, draft.version != expectedVersion else { throw BoomError.stale("The unsent draft changed.") }
      guard draft.attachments.allSatisfy({ id in state.attachments.contains(where: { $0.id == id }) }) else {
        throw BoomError.stale("An unsent attachment is no longer available.")
      }
      product.drafts[index] = draft
    }.0
  }
  func blessengerAdmit(_ turn: BlessengerPreparedTurn) throws -> WorkspaceState {
    guard turn.responseIDs.count == turn.receipts.count, turn.voices.count == turn.receipts.count,
      (1...4).contains(turn.responseIDs.count), Set(turn.responseIDs).count == turn.responseIDs.count else {
      throw BoomError.invalid("The response plan is inconsistent.")
    }
    // Receipts are immutable attempt inputs. Orphans from a failed later index
    // publication remain private and are included in complete backups.
    for (index, receipt) in turn.receipts.enumerated() {
      guard let attempt = receipt.attemptID, receipt.responseID == turn.responseIDs[index],
        !vault.exists(.receipt, attempt), !vault.exists(.receipt, turn.responseIDs[index]) else {
        throw BoomError.stale("The response identity has already been admitted.")
      }
      try vault.encode(receipt, kind: .receipt, id: attempt)
      try vault.encode(receipt, kind: .receipt, id: turn.responseIDs[index])
    }
    if let caller = turn.caller {
      guard let call = blessengerCall, call.id == caller.callID, call.lastEpoch == caller.epoch,
        call.conversationID == turn.history?.id, call.profile == turn.profile,
        call.pendingDraftDigest == (try BlessengerPolicy.validate(turn.draft).digest) else {
        throw BoomError.stale("The call turn was interrupted or replaced before admission.")
      }
    }
    let next = try blessengerTransaction { state, product in
      if turn.caller == nil {
      guard let retainedDraft = product.drafts.first(where: { $0.id == turn.draft.id }),
        try BlessengerPolicy.validate(retainedDraft).digest == BlessengerPolicy.validate(turn.draft).digest,
        try BlessengerPolicy.validate(turn.draft).sendable else { throw BoomError.stale("The submitted draft changed.") }
      let currentProfile = product.addresses[turn.chatID]?.profile ?? product.defaultProfile
      guard currentProfile == turn.profile else { throw BoomError.stale("The conversation model profile changed during preparation.") }
      } else {
        guard try BlessengerPolicy.validate(turn.draft).sendable else { throw BoomError.invalid("The caller supplied no audio.") }
      }
      var forResolution = state; forResolution.blessenger = product
      var routed = turn.draft
      if let address = product.addresses[turn.chatID] { routed.recipients = address.recipients }
      let contacts = try BlessengerPolicy.resolve(host: turn.history?.id, draft: routed,
        state: forResolution, frozen: turn.history != nil)
      guard contacts == turn.contacts else { throw BoomError.stale("The selected Contacts changed.") }
      for source in turn.sourceDigests {
        guard state.attachments.first(where: { $0.id == source.id })?.reference == source else {
          throw BoomError.stale("A submitted attachment changed.")
        }
      }
      let index: Int
      if let history = turn.history {
        guard history.id == turn.chatID, let existing = state.chats.firstIndex(where: { $0.id == history.id }),
          try BlessengerPolicy.exactDigest(state.chats[existing]) == BlessengerPolicy.exactDigest(history),
          !product.attempts.values.contains(where: { $0.conversationID == history.id }) else {
          throw BoomError.stale("The conversation changed while the response was prepared.")
        }
        index = existing
      } else {
        guard !state.chats.contains(where: { $0.id == turn.chatID }) else { throw BoomError.stale("The conversation ID is already in use.") }
        let title = turn.draft.groupName ?? String(turn.draft.text.split(whereSeparator: \.isNewline).first?.prefix(72) ?? "Message")
        state.chats.append(ChatRecord(id: turn.chatID, title: title.isEmpty ? "Voice message" : title))
        index = state.chats.count - 1
        product.addresses[turn.chatID] = BlessengerAddress(recipients: contacts, profile: turn.profile)
        if contacts.count > 1, let name = turn.draft.groupName {
          let handle = try ProductCore.suggestedSlug(name, occupied: state.voices.map(\.slug) + product.groups.map(\.handle))
          product.groups.append(BlessengerGroup(id: UUID(), handle: handle, name: name, members: contacts))
        }
      }
      state.chats[index].messages.append(ChatMessage(role: .user, text: turn.draft.text,
        context: turn.context, sources: turn.sourceDigests, directAttachments: turn.draft.attachments,
        consultationRouting: contacts.map(\.handle), consultationPromptContract: .referenceHistoryV2))
      for i in turn.responseIDs.indices {
        let id = turn.responseIDs[i], receipt = turn.receipts[i]
        let identity = GenerationIdentity(kind: .consultation, operationID: receipt.operationID,
          recordID: id, attemptID: receipt.attemptID!, model: receipt.model, seed: receipt.seed,
          requestDigest: Digest.sha256(receipt.plan.rawPrompt), maxTokens: turn.outputLimit, generationPolicy: receipt.generationPolicy)
        state.chats[index].messages.append(ChatMessage(id: id, role: .assistant, text: "", state: .pending,
          provider: receipt.model, speaker: turn.voices[i]?.speaker ?? Speaker(name: "Blessenger")))
        if let speech = turn.speech {
          if product.spokenResponses == nil { product.spokenResponses = [:] }
          product.spokenResponses?[id] = speech
          if turn.caller != nil { if product.callResponses == nil { product.callResponses = [] }; product.callResponses?.insert(id) }
        }
        product.attempts[id] = BlessengerAttempt(conversationID: turn.chatID, messageID: id,
          identity: identity, sourceDigests: turn.sourceDigests)
      }
      if turn.caller == nil {
        product.drafts.removeAll { $0.id == turn.draft.id }
        product.drafts.append(BlessengerDraft(id: turn.draft.id))
      }
      if turn.draft.id != turn.chatID, !product.drafts.contains(where: { $0.id == turn.chatID }) {
        product.drafts.append(BlessengerDraft(id: turn.chatID))
      }
      if state.selectedChat == turn.history?.id && product.selectedTemplate == nil { state.selectedChat = turn.chatID }
    }.0
    if let caller = turn.caller, blessengerCall?.id == caller.callID {
      blessengerCall?.conversationID = turn.chatID; blessengerCall?.pendingDraftDigest = nil
    }
    return next
  }
  func blessengerFinish(_ receipt: ConsultationReceipt, messageID: UUID, text: String,
    speech: BlessengerSpeechResult? = nil) throws -> WorkspaceState {
    guard receipt.state != .pending, let attemptID = receipt.attemptID,
      let product = blessengerRuntime?.blessenger, let attempt = product.attempts[messageID],
      attempt.identity.attemptID == attemptID, attempt.identity.operationID == receipt.operationID,
      receipt.responseID == messageID, receipt.model == attempt.identity.model,
      receipt.seed == attempt.identity.seed,
      Digest.sha256(receipt.plan.rawPrompt) == attempt.identity.requestDigest,
      receipt.generationPolicy == attempt.identity.generationPolicy else {
      throw BoomError.stale("This response no longer owns its message.")
    }
    let audioRecord: AttachmentImport?
    let retainedAudio: BlessengerAudio?
    if let speech, !speech.samples.isEmpty {
      guard speech.responseID == messageID, speech.attempt == attemptID,
        product.spokenResponses?[messageID] == speech.voice else { throw BoomError.stale("Speech lost its captured response or route.") }
      let original = try speech.wav()
      let imported = try AttachmentProcessor.inspect(name: "Reply audio.wav", data: original)
      guard imported.record.kind == .audio else { throw BoomError.invalid("Generated speech failed audio inspection.") }
      try vault.put(imported.original, kind: .attachment, id: imported.record.id)
      try vault.put(imported.receipt, kind: .receipt, id: imported.record.id)
      audioRecord = imported
      retainedAudio = BlessengerAudio(attachmentID: imported.record.id, textDigest: Digest.sha256(text),
        frames: speech.samples.count, sampleRate: speech.sampleRate, voice: speech.voice,
        interrupted: speech.interrupted, heardFrames: speech.heardFrames, deliveredText: speech.deliveredText,
        attemptID: attemptID, failure: speech.failure)
    } else { audioRecord = nil; retainedAudio = nil }
    // Capture output before the terminal workspace commit; replay never sends.
    try vault.encode(receipt, kind: .receipt, id: attemptID)
    try vault.encode(receipt, kind: .receipt, id: messageID)
    return try blessengerTransaction { state, product in
      guard product.attempts[messageID] == attempt,
        let c = state.chats.firstIndex(where: { $0.id == attempt.conversationID }),
        let m = state.chats[c].messages.firstIndex(where: { $0.id == messageID }),
        state.chats[c].messages[m].state == .pending else { throw BoomError.stale("The response was already settled.") }
      // Revocation forbids a successful publication, not cancellation/failure
      // settlement. A failed attempt must never strand a conversation as busy.
      if receipt.state == .complete {
        for source in attempt.sourceDigests {
          guard state.attachments.first(where: { $0.id == source.id })?.reference == source else {
            throw BoomError.stale("A response source changed before publication.")
          }
        }
      }
      if let audioRecord, let retainedAudio {
        state.attachments.append(audioRecord.record); product.audio[messageID] = retainedAudio
      }
      if let speech {
        if product.traces == nil { product.traces = [:] }
        product.traces?[messageID] = speech.trace.snapshot()
      }
      state.chats[c].messages[m].text = text
      state.chats[c].messages[m].state = receipt.state
      state.chats[c].messages[m].failure = receipt.failure
      product.attempts.removeValue(forKey: messageID)
    }.0
  }
  func blessengerImport(_ imported: AttachmentImport, draftID: UUID, expectedVersion: UUID) throws -> WorkspaceState {
    guard !vault.exists(.attachment, imported.record.id), !vault.exists(.receipt, imported.record.id) else {
      throw BoomError.stale("The attachment identity is already in use.")
    }
    try vault.put(imported.original, kind: .attachment, id: imported.record.id)
    try vault.put(imported.receipt, kind: .receipt, id: imported.record.id)
    return try blessengerTransaction { state, product in
      guard let d = product.drafts.firstIndex(where: { $0.id == draftID }), product.drafts[d].version == expectedVersion else {
        throw BoomError.stale("The destination draft changed while importing. Its private original was retained.")
      }
      state.attachments.append(imported.record)
      product.drafts[d].attachments.append(imported.record.id); product.drafts[d].version = UUID()
      _ = try BlessengerPolicy.validate(product.drafts[d])
    }.0
  }
}

extension WorkspaceStore {
  func blessengerBeginCall(selection: UUID?, expectedDraftVersion: UUID) throws -> BlessengerCallContext {
    guard blessengerCall == nil, let state = blessengerRuntime, let product = state.blessenger,
      state.selectedChat == selection, product.selectedTemplate == nil else {
      throw BoomError.stale("The call destination changed.")
    }
    var draft = product.draft(for: selection)
    guard draft.version == expectedDraftVersion,
      !product.attempts.values.contains(where: { $0.conversationID == selection }) else {
      throw BoomError.stale("The conversation is not ready for a call.")
    }
    // Unsent text remains authored text, not an implicit call question or routing command.
    draft.text = ""; draft.attachments = []
    if let selection, let address = product.addresses[selection] { draft.recipients = address.recipients }
    let recipients = try BlessengerPolicy.resolve(host: selection, draft: draft, state: state, frozen: selection != nil)
    guard recipients.count <= 1 else { throw BoomError.unavailable("Calls currently support one Contact at a time.") }
    let call = BlessengerCallContext(id: UUID(), conversationID: selection, recipients: recipients,
      profile: selection.flatMap { product.addresses[$0]?.profile } ?? product.defaultProfile)
    blessengerCall = call
    return call
  }
  func blessengerEndCall(_ id: UUID) {
    if blessengerCall?.id == id { blessengerCall = nil }
  }
  func blessengerCallerTurn(_ imported: AttachmentImport, callID: UUID, epoch: UInt64,
    flag: CancellationFlag) throws -> BlessengerCallerTurn {
    try flag.check()
    guard var call = blessengerCall, call.id == callID, epoch > call.lastEpoch,
      !vault.exists(.attachment, imported.record.id), !vault.exists(.receipt, imported.record.id) else {
      throw BoomError.stale("The caller audio belongs to an expired call turn.")
    }
    try vault.put(imported.original, kind: .attachment, id: imported.record.id)
    try vault.put(imported.receipt, kind: .receipt, id: imported.record.id)
    var draft = BlessengerDraft(id: call.conversationID ?? UUID())
    draft.recipients = call.recipients; draft.attachments = [imported.record.id]
    let digest = try BlessengerPolicy.validate(draft).digest
    try flag.check()
    let snapshot = try blessengerTransaction { state, _ in
      state.attachments.append(imported.record)
    }.0
    call.lastEpoch = epoch; call.pendingDraftDigest = digest; blessengerCall = call
    return BlessengerCallerTurn(callID: callID, epoch: epoch, draft: draft, snapshot: snapshot,
      conversationID: call.conversationID, profile: call.profile)
  }
}
