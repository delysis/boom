import BoomCore
import SwiftUI

struct ImportedFolderRows: View {
  @ObservedObject var model: WorkspaceModel
  let folder: ImportedFolder
  @State private var expanded = true
  var body: some View {
    DisclosureGroup(folder.name, isExpanded: Binding(get: { !model.librarySearch.isEmpty || expanded }, set: { expanded = $0 })) {
      ImportedDirectoryRows(model: model, folderID: folder.id, prefix: "")
    }.font(.system(size: 13)).padding(.horizontal, 14).padding(.vertical, 8)
  }
}

struct ImportedDirectoryRows: View {
  @ObservedObject var model: WorkspaceModel
  let folderID: UUID
  let prefix: String
  @State private var expanded: Set<String> = []
  private var entries: [(DocumentSnapshot, ImportedFile)] {
    model.documents.compactMap { document in
      guard let file = model.state.importedFiles?[document.id], file.folderID == folderID,
        file.path.hasPrefix(prefix), model.documentMatchesSearch(document) else { return nil }
      return (document, file)
    }.sorted { $0.1.path < $1.1.path }
  }
  private var folders: [String] {
    Array(Set(entries.compactMap { _, file in
      let remaining = file.path.dropFirst(prefix.count)
      guard let slash = remaining.firstIndex(of: "/") else { return nil }
      return String(remaining[..<slash])
    })).sorted()
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(folders, id: \.self) { name in
        DisclosureGroup(name, isExpanded: Binding(get: { !model.librarySearch.isEmpty || expanded.contains(name) }, set: { value in if value { expanded.insert(name) } else { expanded.remove(name) } })) {
          AnyView(ImportedDirectoryRows(model: model, folderID: folderID, prefix: prefix + name + "/"))
        }
      }
      ForEach(entries.filter { !$0.1.path.dropFirst(prefix.count).contains("/") }, id: \.0.id) { document, _ in
        Button { model.selectDocument(document.id) } label: {
          Label(document.title, systemImage: "doc.text").lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6).padding(.horizontal, 7)
            .background(model.state.selectedDocument == document.id ? Color.primary.opacity(0.075) : .clear,
              in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain)
          .contextMenu {
            Button("New chat about this document") {
              do { try model.newChat(about: document.id) } catch { model.report(error) }
            }
            Button("Export Markdown…") { model.exportDocument(document.id) }
            Button("Delete Document…", role: .destructive) { model.deleteDocuments([document.id]) }
          }
      }
    }.font(.system(size: 13))
  }
}

struct DocumentChatHistory: View {
  @ObservedObject var model: WorkspaceModel
  private var chats: [ChatRecord] {
    model.state.chats.filter { $0.attachedDocumentID == model.state.selectedDocument &&
      model.chatVoice($0.id) == nil && model.chatMatchesSearch($0) }
  }
  var body: some View {
    HStack {
      Menu {
        if let selected = model.selectedChat, !chats.contains(where: { $0.id == selected.id }) {
          Button(selected.title) { model.selectChat(selected.id) }
          Divider()
        }
        ForEach(chats) { chat in
          Button(chat.title) { model.selectChat(chat.id) }
        }
        if chats.isEmpty { Text("No chats about this document") }
        Divider()
        Button("New chat about this document") {
          do { try model.newChat(about: model.state.selectedDocument) } catch { model.report(error) }
        }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "bubble.left")
          Text(model.selectedChat?.title ?? "Conversations").lineLimit(1)
        }.font(.system(size: 12))
      }.menuStyle(.borderlessButton).disabled(model.isBusy)
      Spacer(minLength: 4)
      Button {
        do { try model.newChat(about: model.state.selectedDocument) } catch { model.report(error) }
      } label: {
        Image(systemName: "square.and.pencil")
          .frame(width: WorkspaceGeometry.controlSize, height: WorkspaceGeometry.controlSize)
          .contentShape(Rectangle())
      }
        .buttonStyle(.plain)
        .help("New chat about this document").disabled(model.isBusy)
    }.frame(height: WorkspaceGeometry.headerHeight)
      .foregroundStyle(.secondary).padding(.horizontal, WorkspaceGeometry.paneInset)
      .padding(.top, WorkspaceGeometry.paneInset).padding(.bottom, 8)
  }
}
