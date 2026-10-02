import Foundation

/// A transient selection for one library section. The open item remains a
/// separate primary selection so Command-click can deselect every row.
public struct LibrarySelection: Equatable {
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
  ) -> (open: Bool, rename: Bool) {
    guard visible.contains(id) else { return (false, false) }
    switch gesture {
    case .plain:
      if ids == [id], primary == id { return (false, true) }
      ids = [id]
      anchor = id
      return (true, false)
    case .toggle:
      anchor = id
      if ids.contains(id) {
        ids.remove(id)
        return (false, false)
      }
      ids.insert(id)
      return (true, false)
    case .range, .additiveRange:
      guard let origin = anchor ?? primary, let start = visible.firstIndex(of: origin),
        let end = visible.firstIndex(of: id) else {
        ids = gesture == .range ? [id] : ids.union([id])
        anchor = id
        return (true, false)
      }
      let span = Set(visible[min(start, end)...max(start, end)])
      ids = gesture == .range ? span : ids.union(span)
      return (true, false)
    }
  }
}
