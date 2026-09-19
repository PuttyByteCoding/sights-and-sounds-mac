import Foundation

extension Array where Element: Identifiable, Element.ID == UUID {
    /// The array with `id` moved before `target` (or last, for nil) —
    /// the one drop rule the Search String tab's parts and rules share.
    /// Dropping a row on itself, or naming an unknown row, changes
    /// nothing; an unknown target puts the row last.
    func moving(_ id: UUID, before target: UUID?) -> [Element] {
        guard let from = firstIndex(where: { $0.id == id }), id != target else { return self }
        var rows = self
        let moved = rows.remove(at: from)
        if let target, let to = rows.firstIndex(where: { $0.id == target }) {
            rows.insert(moved, at: to)
        } else {
            rows.append(moved)
        }
        return rows
    }
}
