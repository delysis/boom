import Foundation

/// A transient selection for one library section. The open item remains a
/// separate primary selection so Command-click can deselect every row.
public struct LibrarySelection: Equatable {
  public enum Effect: Equatable { case none, open, rename }
  public enum Click: Equatable { case plain, toggle, range, additiveRange }
  public var ids: Set<UUID>
  public var anchor: UUID?
  public init(ids: Set<UUID> = [], anchor: UUID? = nil) {
    self.ids = ids
    self.anchor = anchor
  }
  /// Returns whether the clicked row should open or rename its item.
  public mutating func click(
    _ id: UUID, visible: [UUID], primary: UUID?, gesture: Click
  ) -> Effect {
    guard visible.contains(id) else { return .none }
    switch gesture {
    case .plain:
      if ids == [id], primary == id { return .rename }
      ids = [id]
      anchor = id
      return .open
    case .toggle:
      anchor = id
      if ids.contains(id) {
        ids.remove(id)
        return .none
      }
      ids.insert(id)
      return .open
    case .range, .additiveRange:
      guard let origin = anchor ?? primary, let start = visible.firstIndex(of: origin),
        let end = visible.firstIndex(of: id) else {
        ids = gesture == .range ? [id] : ids.union([id])
        anchor = id
        return .open
      }
      let span = Set(visible[min(start, end)...max(start, end)])
      ids = gesture == .range ? span : ids.union(span)
      return .open
    }
  }
}
