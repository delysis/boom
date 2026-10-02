#if BOOM_UI_TEST
import AppKit
import BoomCore
import Foundation

/// Uses an isolated workspace and the same decoder and owner methods as the
/// two editors. This catches routing and persistence errors without touching
/// the user's documents or requiring model or microphone access.
@MainActor enum AttachmentRouteSmoke {
  private static func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw BoomError.invalid(message) }
  }

  private static func finish(_ model: WorkspaceModel) async throws {
    for _ in 0..<200 where model.isBusy {
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    try require(!model.isBusy, "Attachment import did not finish.")
    if let error = model.errorMessage { throw BoomError.invalid(error) }
    try model.flush()
  }

  static func run() async throws {
    guard let root = ProcessInfo.processInfo.environment["BOOM_UI_TEST_ROOT"],
      root.hasPrefix("/"), !FileManager.default.fileExists(atPath: root)
    else { throw BoomError.denied("Supply a new absolute BOOM_UI_TEST_ROOT.") }
    let model = try WorkspaceModel()
    guard let first = model.selectedDocument else {
      throw BoomError.invalid("No initial document.")
    }
    let source = model.store.root.appendingPathComponent("route-source.txt")
    try Data("owner is the first document".utf8).write(to: source)
    let fileBoard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
    fileBoard.clearContents()
    try require(fileBoard.writeObjects([source as NSURL]), "Could not prepare file pasteboard.")
    guard let fileInput = AttachmentInput.read(fileBoard) else {
      throw BoomError.invalid("File paste was not decoded.")
    }
    let firstDestination = model.documentAttachmentDestination(id: first.id, range: NSRange(location: 0, length: 0))!
    try model.newDocument()
    let second = model.selectedDocument!.id
    model.attach(fileInput, to: firstDestination)
    try await finish(model)
    guard let savedFirst = model.documents.first(where: { $0.id == first.id }) else {
      throw BoomError.invalid("Original document disappeared.")
    }
    try require(savedFirst.text.contains("boom-attachment:"), "File link missed its document.")
    try require(model.selectedDocument?.id == second && model.selectedDocument?.text.isEmpty == true,
      "File was routed to the selected document instead of its owner.")
    try require(model.pendingAttachments.isEmpty, "Document file leaked into chat attachments.")
    let linked = AttachmentLink.ids(in: savedFirst.text)
    try require(linked.count == 1 && model.state.attachments.first(where: { $0.id == linked[0] })?.text
      .contains("owner is the first document") == true, "Document file was not converted locally.")
    try require(try model.store.load().get().1.first(where: { $0.id == first.id })?.text
      == savedFirst.text, "Document link did not persist.")

    guard let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0),
      let png = bitmap.representation(using: .png, properties: [:])
    else { throw BoomError.invalid("Could not prepare test image.") }
    let imageBoard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
    imageBoard.clearContents()
    imageBoard.setData(png, forType: .png)
    guard let imageInput = AttachmentInput.read(imageBoard) else {
      throw BoomError.invalid("Image paste was not decoded.")
    }
    model.attachToCurrentChat(imageInput)
    try await finish(model)
    try require(model.pendingAttachments.count == 1, "Image missed its chat.")
    try require(model.selectedDocument?.text.isEmpty == true,
      "Chat image leaked into the selected document.")
    try require(model.state.attachments.contains(where: { $0.id == model.pendingAttachments[0] }),
      "Chat image was not saved as an attachment.")
    print("attachment_route_smoke_passed")
  }
}
#endif
