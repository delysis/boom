import BoomCore
import Foundation

extension BlessengerProfile {
  /// Discovery may resolve an unbound preference once. A bound conversation
  /// never follows a mutable directory or a newly selected global default.
  func resolvingModel(path: String, identity: String) throws -> Self {
    var resolved = self
    resolved.modelPath = URL(fileURLWithPath: path).standardizedFileURL.path
    resolved.modelIdentity = identity
    try admitResolution(resolved)
    return resolved
  }
  func admitResolution(_ resolved: Self) throws {
    try BlessengerState.validate(self); try BlessengerState.validate(resolved)
    guard let path = resolved.modelPath, resolved.modelIdentity != nil,
      id == resolved.id, sampling == resolved.sampling,
      maximumTokens == resolved.maximumTokens, useMTP == resolved.useMTP,
      modelPath.map({ URL(fileURLWithPath: $0).standardizedFileURL.path == path }) ?? true,
      modelIdentity.map({ $0 == resolved.modelIdentity }) ?? true else {
      throw BoomError.stale("The loaded model does not match this conversation. Choose a model explicitly in Settings; no input was sent.")
    }
  }
  func requireBinding(for history: ChatRecord?, caller: Bool = false) throws {
    // A caller's first authored audio can precede response preparation. Its
    // captured call profile is bound at startup; an old conversation is not.
    guard modelIdentity != nil || (!caller && history?.messages.isEmpty != false) else {
      throw BoomError.unavailable("This conversation has no recorded model binding. Select its model explicitly in Settings before continuing; its history is unchanged.")
    }
  }
}

extension BlessengerState {
  /// Shared by ordinary persistence and backup admission. Historical branch
  /// edges and retained messages are data, not permission to invent ancestry.
  func validateRelationships(in state: WorkspaceState) throws {
    let chats = Set(state.chats.map(\.id)), removed = removedConversations ?? []
    guard state.chats.count <= 4096, branches.count <= 16384, removed.count <= 16384,
      chats.count == state.chats.count, removed.isDisjoint(with: chats),
      state.documents.isEmpty, state.archivedDocuments?.isEmpty ?? true, state.candidateIDs.isEmpty,
      state.selectedChat.map(chats.contains) ?? true,
      selectedTemplate.map({ id in state.selectedChat == id && state.voices.contains { $0.id == id } }) ?? true else {
      throw BoomError.invalid("The private conversation index contains inconsistent owners.")
    }
    let ancestry = chats.union(removed)
    guard branches.allSatisfy({ ancestry.contains($0.key) && ancestry.contains($0.value) && $0.key != $0.value }) else {
      throw BoomError.invalid("A branch refers to missing or self-referential ancestry.")
    }
    var complete = Set<UUID>()
    for origin in branches.keys where !complete.contains(origin) {
      var path = Set<UUID>(), current: UUID? = origin
      while let id = current, !complete.contains(id) {
        guard path.insert(id).inserted else { throw BoomError.invalid("Conversation ancestry contains a cycle.") }
        current = branches[id]
      }
      complete.formUnion(path)
    }
    let attachments = Set(state.attachments.map(\.id))
    guard attachments.count == state.attachments.count else { throw BoomError.invalid("Duplicate private originals.") }
    var messages = Set<UUID>()
    for chat in state.chats {
      guard Set(chat.messages.map(\.id)).count == chat.messages.count,
        Set((chat.messageVersions ?? []).map(\.id)).count == (chat.messageVersions ?? []).count else {
        throw BoomError.invalid("A conversation contains duplicate message identities.")
      }
      for message in chat.messages + (chat.messageVersions ?? []) {
        messages.insert(message.id)
        let direct = message.directAttachments ?? []
        guard Set(direct).count == direct.count, direct.allSatisfy(attachments.contains),
          message.sources.filter({ $0.kind == "attachment" }).allSatisfy({ attachments.contains($0.id) }) else {
          throw BoomError.invalid("A retained message refers to a missing private original.")
        }
      }
    }
    for (id, address) in addresses {
      guard chats.contains(id) else { throw BoomError.invalid("Addressing has no live conversation.") }
      var witness = BlessengerDraft(id: id); witness.recipients = address.recipients
      _ = try BlessengerPolicy.validate(witness)
    }
    for (id, audio) in audio {
      guard messages.contains(id), audio.textDigest.count == 64,
        audio.textDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
        throw BoomError.invalid("Retained speech has lost its response identity.")
      }
    }
    guard (spokenResponses ?? [:]).keys.allSatisfy(messages.contains),
      (callResponses ?? []).allSatisfy(messages.contains),
      (traces ?? [:]).keys.allSatisfy(messages.contains) else {
      throw BoomError.invalid("Speech delivery metadata has lost its message.")
    }
  }
  mutating func removeConversation(_ id: UUID, from state: inout WorkspaceState) {
    state.chats.removeAll { $0.id == id }; drafts.removeAll { $0.id == id }
    addresses.removeValue(forKey: id)
    if removedConversations == nil { removedConversations = [] }
    removedConversations?.insert(id)
    let messages = Set(state.chats.flatMap { $0.messages + ($0.messageVersions ?? []) }.map(\.id))
    audio = audio.filter { messages.contains($0.key) }
    spokenResponses = spokenResponses?.filter { messages.contains($0.key) }
    callResponses = callResponses?.intersection(messages)
    traces = traces?.filter { messages.contains($0.key) }
    if state.selectedChat == id { state.selectedChat = nil; selectedTemplate = nil }
  }
}
