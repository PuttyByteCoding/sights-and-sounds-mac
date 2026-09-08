import Foundation

/// One row of the player's tag panel: a category, or one of the two
/// fields that live among them. The panel's order is a list of these,
/// so a drop can mean exactly "before that row" — the earlier scheme of
/// per-field numbers meaning "before category N" could not say where a
/// category goes relative to a field, and two fields on one number
/// always drew in a fixed order whatever was dropped on what.
@MainActor
enum PanelRow: Hashable, Sendable {
    case category(UUID)
    case universal
    case results

    /// The stored form.
    var key: String {
        switch self {
        case .category(let id): id.uuidString
        case .universal: "universal"
        case .results: "results"
        }
    }

    init?(key: String) {
        switch key {
        case "universal": self = .universal
        case "results": self = .results
        default:
            guard let id = UUID(uuidString: key) else { return nil }
            self = .category(id)
        }
    }

    /// The id the panel's focus walk and drag payload use: a category's
    /// own id, or a field's fixed sentinel.
    var focusID: UUID {
        switch self {
        case .category(let id): id
        case .universal: PlayerModel.universalFieldFocusID
        case .results: PlayerModel.analysisResultsFieldFocusID
        }
    }

    init(focusID: UUID) {
        switch focusID {
        case PlayerModel.universalFieldFocusID: self = .universal
        case PlayerModel.analysisResultsFieldFocusID: self = .results
        default: self = .category(focusID)
        }
    }

    var categoryID: UUID? {
        if case .category(let id) = self { return id }
        return nil
    }
}

@MainActor
enum TagPanelOrder {
    static let pseudoRows: [PanelRow] = [.universal, .results]

    /// The panel's rows: the stored order reconciled against the
    /// vocabulary (unknown keys dropped, new categories appended in
    /// vocabulary order, a missing field appended), or — with nothing
    /// stored — the vocabulary with the fields at the positions the
    /// older settings held.
    static func rows(
        vocabulary: [UUID], stored: [String],
        seed: (universal: Int, results: Int)
    ) -> [PanelRow] {
        let known = Set(vocabulary)
        var rows = stored.compactMap(PanelRow.init(key:)).filter {
            $0.categoryID.map { known.contains($0) } ?? true
        }
        if rows.isEmpty {
            rows = PlayerModel.tagFieldOrder(
                searchCategoryIDs: vocabulary, universalPosition: seed.universal,
                resultsPosition: seed.results
            ).map(PanelRow.init(focusID:))
        }
        var seen = Set(rows)
        for id in vocabulary where !seen.contains(.category(id)) {
            rows.append(.category(id))
            seen.insert(.category(id))
        }
        for pseudo in pseudoRows where !seen.contains(pseudo) {
            rows.append(pseudo)
        }
        return rows
    }

    /// Move a row before another (nil = to the end). Onto itself, or a
    /// row not in the list, changes nothing.
    static func moved(_ rows: [PanelRow], _ row: PanelRow, before target: PanelRow?) -> [PanelRow] {
        guard row != target, let from = rows.firstIndex(of: row) else { return rows }
        var result = rows
        result.remove(at: from)
        let to = target.flatMap { result.firstIndex(of: $0) } ?? result.count
        result.insert(row, at: to)
        return result
    }
}
