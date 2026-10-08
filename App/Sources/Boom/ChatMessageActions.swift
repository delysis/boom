import AppKit
import BoomCore
import SwiftUI

/// One set of captured targets serves the hover rail and the context menu.
@MainActor struct ChatMessageCommands {
  let model: WorkspaceModel
  let chatID: UUID
  let message: ChatMessage
  var pasteboard = NSPasteboard.general
  var canEdit: Bool { !model.isBusy && model.editingChatMessage == nil && message.state == .complete }
  var canBranch: Bool { !model.isBusy && model.editingChatMessage == nil && message.state != .pending }
  var canRate: Bool { canEdit && message.role == .assistant }
  func copy() {
    pasteboard.clearContents()
    pasteboard.setString(message.text.isEmpty ? message.failure ?? "" : message.text, forType: .string)
  }
  func edit() {
    guard canEdit, model.state.selectedChat == chatID else { return }
    model.editingChatMessage = message.id
  }
  func branch() { if canBranch { model.branch(message.id, from: chatID) } }
  func continueEditing() { if canEdit { model.branch(message.id, from: chatID, editing: true) } }
  func regenerate() { if canEdit { model.regenerate(message.id, from: chatID) } }
  func rate(_ feedback: MessageFeedback) { if canRate { model.rate(message.id, in: chatID, as: feedback) } }

  @ViewBuilder var menu: some View {
    Button("Copy", systemImage: "square.on.square", action: copy)
    Button("Edit", systemImage: "pencil", action: edit).disabled(!canEdit)
    Button("Branch", systemImage: "arrow.triangle.branch", action: branch).disabled(!canBranch)
    if message.role == .user {
      Button("Edit & Continue", action: continueEditing).disabled(!canEdit)
    } else {
      Button("Regenerate in new branch", action: regenerate).disabled(!canEdit)
      Divider()
      Button(message.feedback == .helpful ? "Remove thumbs up" : "Thumbs up", systemImage: "hand.thumbsup") { rate(.helpful) }
        .disabled(!canRate)
      Button(message.feedback == .unhelpful ? "Remove thumbs down" : "Thumbs down", systemImage: "hand.thumbsdown") { rate(.unhelpful) }
        .disabled(!canRate)
    }
    if message.editedFrom != nil { Text("Edited by you · original retained") }
    else if message.authoredByUser == true && message.role == .assistant { Text("Written by you") }
  }
}

struct ChatMessageRow<Content: View>: View {
  let commands: ChatMessageCommands
  @ViewBuilder let content: () -> Content
  @State private var hovered = false
  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      content()
      ChatMessageActions(commands: commands, hovered: hovered).frame(height: 24)
    }
    .contentShape(Rectangle())
    .onHover { hovered = $0 }
    .contextMenu { commands.menu }
  }
}

private struct ChatMessageActions: NSViewRepresentable {
  let commands: ChatMessageCommands
  let hovered: Bool
  func makeNSView(context: Context) -> ChatMessageActionView { ChatMessageActionView(commands: commands) }
  func updateNSView(_ view: ChatMessageActionView, context: Context) {
    view.update(commands: commands)
    view.setHovered(hovered)
  }
}

/// Reserve one small rail so pointer entry never shifts the transcript. Native
/// buttons keep focus, accessibility, menus and hit regions in one layout owner.
@MainActor final class ChatMessageActionView: NSView {
  private(set) var commands: ChatMessageCommands
  let copyButton = MessageActionButton()
  let editButton = MessageActionButton()
  let branchButton = MessageActionButton()
  let feedbackButton: MessageActionButton?
  let timestamp = NSTextField(labelWithString: "")
  private var hovered = false
  private weak var focusedButton: MessageActionButton?
  private var menuIsOpen = false
  private(set) var revealed = false
  private var items: [NSView] { [timestamp, copyButton, editButton, branchButton] + (feedbackButton.map { [$0] } ?? []) }

  init(commands: ChatMessageCommands) {
    self.commands = commands
    feedbackButton = commands.message.role == .assistant ? MessageActionButton() : nil
    super.init(frame: .zero)
    configure(copyButton, symbol: "square.on.square", label: "Copy message", action: #selector(copyMessage))
    configure(editButton, symbol: "pencil", label: "Edit message", action: #selector(editMessage))
    configure(branchButton, symbol: "arrow.triangle.branch", label: "Branch from this message", action: #selector(branchMessage))
    if let feedbackButton { configure(feedbackButton, symbol: "hand.thumbsup", label: "Feedback", action: #selector(showFeedback)) }
    timestamp.font = .systemFont(ofSize: 11)
    timestamp.textColor = .secondaryLabelColor
    timestamp.setContentCompressionResistancePriority(.required, for: .horizontal)
    let controls: [NSView] = [copyButton, editButton, branchButton] + (feedbackButton.map { [$0] } ?? [])
    let stack = NSStackView(views: commands.message.role == .user ? [timestamp] + controls : controls + [timestamp])
    stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = 4
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)])
    if commands.message.role == .user {
      stack.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
      stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor).isActive = true
    } else {
      stack.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
      stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor).isActive = true
    }
    update(commands: commands)
    updateVisibility()
  }
  required init?(coder: NSCoder) { return nil }

  private func configure(_ button: MessageActionButton, symbol: String, label: String, action: Selector) {
    button.title = ""; button.target = self; button.action = action
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
      .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
    button.isBordered = false; button.bezelStyle = .accessoryBarAction
    button.contentTintColor = .secondaryLabelColor
    button.toolTip = label; button.setAccessibilityLabel(label)
    button.focusChanged = { [weak self, weak button] focused in
      guard let self, let button else { return }
      if focused { self.focusedButton = button }
      else if self.focusedButton === button { self.focusedButton = nil }
      self.updateVisibility()
    }
    button.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 24), button.heightAnchor.constraint(equalToConstant: 24)])
  }
  func update(commands: ChatMessageCommands) {
    self.commands = commands
    let message = commands.message
    setAccessibilityIdentifier("message-actions-" + message.id.uuidString)
    for (button, name) in [(copyButton, "copy"), (editButton, "edit"), (branchButton, "branch")] {
      button.setAccessibilityIdentifier("message-" + name + "-" + message.id.uuidString)
    }
    editButton.isEnabled = commands.canEdit; branchButton.isEnabled = commands.canBranch
    feedbackButton?.isEnabled = commands.canRate
    feedbackButton?.setAccessibilityIdentifier("message-feedback-" + message.id.uuidString)
    let feedbackSymbol = message.feedback == .helpful ? "hand.thumbsup.fill"
      : message.feedback == .unhelpful ? "hand.thumbsdown.fill" : "hand.thumbsup"
    feedbackButton?.image = NSImage(systemSymbolName: feedbackSymbol, accessibilityDescription: "Feedback")?
      .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
    if let date = message.timestamp {
      timestamp.stringValue = date.formatted(date: .omitted, time: .shortened)
      timestamp.toolTip = date.formatted(date: .complete, time: .standard)
      timestamp.setAccessibilityLabel(timestamp.toolTip)
    } else { timestamp.stringValue = ""; timestamp.toolTip = nil; timestamp.setAccessibilityLabel(nil) }
    timestamp.isHidden = message.timestamp == nil
  }
  func setHovered(_ value: Bool) { hovered = value; updateVisibility() }
  private func updateVisibility() {
    revealed = hovered || focusedButton != nil || menuIsOpen
    for item in items { item.alphaValue = revealed ? 1 : 0 }
  }
  override func hitTest(_ point: NSPoint) -> NSView? { revealed ? super.hitTest(point) : nil }
  override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateVisibility() }

  @objc private func copyMessage() { commands.copy() }
  @objc private func editMessage() { commands.edit() }
  @objc private func branchMessage() { commands.branch() }
  @objc private func showFeedback() {
    guard let feedbackButton else { return }
    menuIsOpen = true; updateVisibility()
    defer { menuIsOpen = false; updateVisibility() }
    let menu = feedbackMenu()
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: feedbackButton.bounds.maxY + 3), in: feedbackButton)
  }
  func feedbackMenu() -> NSMenu {
    let menu = NSMenu()
    for (title, symbol, action, feedback) in [
      ("Helpful", "hand.thumbsup", #selector(helpful), MessageFeedback.helpful),
      ("Unhelpful", "hand.thumbsdown", #selector(unhelpful), MessageFeedback.unhelpful),
    ] {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
      item.target = self; item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
      item.state = commands.message.feedback == feedback ? .on : .off
      menu.addItem(item)
    }
    return menu
  }
  @objc private func helpful() { commands.rate(.helpful) }
  @objc private func unhelpful() { commands.rate(.unhelpful) }
}

@MainActor final class MessageActionButton: NSButton {
  var focusChanged: ((Bool) -> Void)?
  override func becomeFirstResponder() -> Bool {
    let result = super.becomeFirstResponder()
    if result { focusChanged?(true) }
    return result
  }
  override func resignFirstResponder() -> Bool {
    let result = super.resignFirstResponder()
    if result { focusChanged?(false) }
    return result
  }
}
