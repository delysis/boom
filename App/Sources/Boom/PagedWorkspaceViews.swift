import AppKit
import BoomCore
import SwiftUI

/// Same product pane, one actual bounded library page. Titles are metadata;
/// a title query here never claims a complete manuscript/full-chat search.
struct PagedWorkspaceLibrary: View {
  @ObservedObject var model: WorkspaceModel
  @State private var renaming: UUID?
  @State private var proposedTitle = ""
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Documents").font(.system(size: 10, weight: .semibold))
        Spacer()
        Button { do { try model.newDocument() } catch { model.report(error) } } label: { Image(systemName: "plus") }
          .buttonStyle(.plain).help("New document").disabled(model.isBusy)
      }.padding(WorkspaceGeometry.paneInset)
      ScrollView {
        LazyVStack(spacing: 2) {
          ForEach(model.documentIndices.filter { model.librarySearch.isEmpty || $0.title.localizedCaseInsensitiveContains(model.librarySearch) }, id: \.id) { document in
            HStack(spacing: 8) {
              Image(systemName: "doc.text").foregroundStyle(.secondary)
              if renaming == document.id {
                TextField("Name", text: $proposedTitle).textFieldStyle(.plain)
                  .onSubmit { model.renameDocument(document.id, to: proposedTitle); renaming = nil }
                  .onExitCommand { renaming = nil }
              } else {
                Button { model.selectDocument(document.id) } label: {
                  Text(document.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).disabled(model.isBusy)
              }
            }.padding(8)
              .background(model.selectedDocumentID == document.id ? Color.primary.opacity(0.075) : .clear,
                in: RoundedRectangle(cornerRadius: 7))
              .contextMenu {
                Button("Rename") { proposedTitle = document.title; renaming = document.id }.disabled(model.isBusy)
                Button("Copy reference") {
                  NSPasteboard.general.clearContents()
                  NSPasteboard.general.setString("[[\(document.title)|\(document.id.uuidString)]]", forType: .string)
                }
                Button("Export") { model.exportDocument(document.id) }.disabled(model.isBusy)
                Button("Delete", role: .destructive) { model.deleteDocuments([document.id]) }.disabled(model.isBusy)
              }
          }
        }.padding(.horizontal, 4)
      }
      HStack {
        Button { model.pagePagedDocuments(forward: false) } label: { Image(systemName: "chevron.left") }
          .disabled(model.isBusy || !model.pagedLibraryHasPrevious).help("Previous library page")
        Spacer()
        if let issue = model.searchIssue { Image(systemName: "exclamationmark.circle").help(issue).accessibilityLabel(issue) }
        Button { model.importDocument() } label: { Image(systemName: "doc.badge.plus") }
          .disabled(model.isBusy).help("Import document")
        Spacer()
        Button { model.pagePagedDocuments(forward: true) } label: { Image(systemName: "chevron.right") }
          .disabled(model.isBusy || model.pagedNextDocumentOrdinal == nil).help("Next library page")
      }.buttonStyle(.plain).padding(WorkspaceGeometry.paneInset)
    }
  }
}

/// Actual active owner draft remains editable/restorable. Header-only chats are
/// intentionally not manufactured ChatRecord values or incomplete transcripts.
/// Typed consultation/message/media hydration is a named activation dependency.
struct PagedWorkspaceComposer: View {
  @ObservedObject var model: WorkspaceModel
  @State private var height: CGFloat = 70
  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        LazyVStack(alignment: .leading) {
          ForEach(model.pagedChatPage, id: \.reference.id) { entity in
            if let index = entity.header.chatIndex {
              Button { model.selectChat(index.id) } label: {
                Label(index.title, systemImage: "bubble.left").lineLimit(1)
              }.buttonStyle(.plain).padding(8)
            }
          }
        }.padding(WorkspaceGeometry.paneInset)
      }
      VStack(spacing: 8) {
        if !model.pendingAttachments.isEmpty {
          HStack {
            ForEach(model.pendingAttachments, id: \.self) { id in
              Image(systemName: "paperclip").accessibilityLabel("Retained attachment \(id.uuidString)")
            }
          }
        }
        ChatComposer(text: Binding(get: { model.draft }, set: {
            if model.hasComposerOwner { model.draft = $0 }
          }), focusRequest: model.composerFocusEpoch,
          onSend: { model.send() }, onCancel: { model.cancel() },
          onFocus: { model.noteInputFocus(.chat) },
          onContentHeight: { height = min(140, max(36, $0)) })
          .frame(height: height).disabled(!model.hasComposerOwner)
        HStack {
          Spacer()
          Button { model.send() } label: { Image(systemName: "arrow.up") }
            .buttonStyle(.plain).help("Consultation requires the bounded capture consumer")
            .disabled(true) // no snapshot/island substitution for a model request
        }
      }.padding(WorkspaceGeometry.inputInset)
        .background(Color(nsColor: BoomChrome.inputBackground), in: RoundedRectangle(cornerRadius: 12))
        .padding(WorkspaceGeometry.paneInset)
    }
  }
}
