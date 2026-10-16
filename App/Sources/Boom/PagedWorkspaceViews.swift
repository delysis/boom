import SwiftUI

/// The ordinary library and composer share metadata owners with every document.
struct PagedWorkspaceLibrary: View {
  @ObservedObject var model: WorkspaceModel
  var body: some View { LibraryView(model: model) }
}
struct PagedWorkspaceComposer: View {
  @ObservedObject var model: WorkspaceModel
  var body: some View { ChatPane(model: model) }
}
