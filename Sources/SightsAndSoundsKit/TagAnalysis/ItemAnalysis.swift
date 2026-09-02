import Foundation
import GRDB

/// Where a surviving string came from — enough for the display to say
/// "embedded metadata · comment" or seek an OCR still.
public struct AnalysisOrigin: Equatable, Sendable, Hashable {
    public let readerID: String
    public let timeSeconds: Double?
    /// The contributing file, for sidecars — nil elsewhere.
    public let sourceFile: String?
}

/// One string the analysis surfaced, after parsing and the rule fold.
public struct AnalysisCandidate: Equatable, Sendable, Identifiable {
    /// The FOLDED value — a stripPrefix rule has already run, so this is
    /// what the tag would be called.
    public let value: String
    public let key: String?
    /// Non-nil when a rule mapped it to a category: the Suggested bucket.
    public let category: String?
    /// Non-nil when an ignore rule struck it. Struck strings stay listed
    /// — that is what keeps a mis-authored ignore rule diagnosable — and
    /// are skipped by existing-tag matching, which is the false-positive
    /// reduction the ignore-words exist for.
    public let suppressedByRule: String?
    /// Non-nil when the category came from a MATCHED JSON SCHEMA rather
    /// than a rule — the decide pane says which one.
    public let mappedBySchema: String?
    /// The road back to the source: the reader's label, then each tool
    /// the recursive walk went through. "Embedded metadata · comment →
    /// jsonParser" is how a value three layers deep stays traceable.
    public let trail: [String]
    public let origins: [AnalysisOrigin]

    public var id: String { "\(KeyNormalizer.normalize(key ?? ""))|\(value.lowercased())" }
}

/// An existing tag whose name (or one of its aliases) appears inside a
/// surviving string — the best possible candidate: nothing to create,
/// just apply.
public struct ExistingTagFinding: Equatable, Sendable, Identifiable {
    public let tag: Tag
    public let categoryName: String
    /// What matched — the tag's own name, or the alias that hit.
    public let matchedText: String
    /// The string it was found inside, for display.
    public let foundIn: String
    /// Already on this video. Shown struck rather than hidden, so "why
    /// isn't this offered" has a visible answer.
    public let alreadyApplied: Bool

    public var id: String { "\(tag.id)|\(foundIn.lowercased())" }
}

/// One reader's half of the ledger: exactly what it handed the
/// pipeline, raw. The processed half needs no storage — every candidate
/// already carries its origins, so "what came OUT of this reader" is a
/// filter over the buckets.
public struct ReaderReport: Equatable, Sendable, Identifiable {
    public let readerID: String
    public let displayName: String
    public let sources: [AnalysisSourceText]
    /// The reader threw. A throwing reader contributes nothing rather
    /// than sinking the run — but silence here made that indistinguishable
    /// from "found nothing", which is exactly what an inspector is for.
    public let error: String?

    public var id: String { readerID }
}

/// Everything the analysis found for one video, bucketed the way the
/// operator triages: rule-mapped first, known tags second, judgment last.
public struct ItemAnalysis: Equatable, Sendable {
    public let suggested: [AnalysisCandidate]
    public let existing: [ExistingTagFinding]
    public let unmapped: [AnalysisCandidate]
    public let md5s: [String]
    /// Schemas that recognised a JSON payload in this video's evidence.
    public let matchedSchemas: [String]
    /// Raw in, per reader, in registration order — the inspector's left
    /// column. What came out is a filter over the buckets by origin.
    public let readerReports: [ReaderReport]
    /// The parse hit its deadline — surfaced where the results are,
    /// because an incomplete list that looks complete is worse than a
    /// visibly incomplete one.
    public let truncated: Bool
    public let provenance: [ProvenanceStep]

    public static let empty = ItemAnalysis(
        suggested: [], existing: [], unmapped: [], md5s: [], matchedSchemas: [],
        readerReports: [], truncated: false, provenance: [])

    /// The analyzer's CAPABILITY version, stamped on every item the
    /// operator advances past. Derived from what the analyzer can read,
    /// not from when it ran:
    ///
    /// **Bump this in any PR that adds a reader or sub-parser** (the
    /// web-page reader, the JSON-schema matcher, …) — that is the review
    /// rule that makes "Analyzed (older)" mean "a re-pass could find
    /// more". Rule edits deliberately do NOT bump it: rules change
    /// weekly, and staleness must mean missing capability, not recency.
    ///
    /// 1 · embedded metadata, path, same-basename sidecars (.txt/.json),
    ///     OCR, the recursive parser.
    /// 2 · JSON schema matching — payloads recognised against authored
    ///     schemas, their key mappings feeding Suggested.
    public static let analyzerVersion = 2
}

/// The visited marker: tag analysis showed the operator this item, under
/// this analyzer. Advancing past without staging anything still counts —
/// seeing the evidence and judging nothing tag-worthy IS an analysis.
public struct TagAnalysisState: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "tagAnalysisState"

    public var mediaItemID: UUID
    public var analyzedAt: Date
    public var analyzerVersion: Int

    public init(
        mediaItemID: UUID, analyzedAt: Date = Date(),
        analyzerVersion: Int = ItemAnalysis.analyzerVersion
    ) {
        self.mediaItemID = mediaItemID
        self.analyzedAt = analyzedAt
        self.analyzerVersion = analyzerVersion
    }
}

/// A tag waiting in the basket — staged, not written. `value` is
/// editable right up to commit: "tapper: Mike Jones" gets trimmed by
/// hand before it becomes a tag.
public struct PendingTag: Equatable, Sendable, Identifiable {
    public let id: UUID
    public var value: String
    public var categoryID: UUID
    /// Set when the pending tag IS an existing tag being applied — commit
    /// assigns it rather than creating anything, even if the display
    /// value was edited.
    public var existingTagID: UUID?

    public init(id: UUID = UUID(), value: String, categoryID: UUID, existingTagID: UUID? = nil) {
        self.id = id
        self.value = value
        self.categoryID = categoryID
        self.existingTagID = existingTagID
    }
}

extension LibraryDatabase {

    /// Stamp the visited marker. Re-visiting under a newer analyzer
    /// upgrades the stored version; re-visiting under the same one just
    /// refreshes the date.
    public func markAnalyzed(_ itemID: UUID) throws {
        try writer.write { db in
            try TagAnalysisState(mediaItemID: itemID).upsert(db)
        }
    }

    /// The default reader set, in display order. A future web-page reader
    /// or schema matcher is appended here — one line, no rewrites.
    public static func defaultAnalysisReaders() -> [any AnalysisReader] {
        [
            EmbeddedMetadataReader(),
            PathAnalysisReader(),
            SidecarTextReader(),
            SidecarJsonReader(),
            OcrAnalysisReader(),
        ]
    }

    /// Run the full analysis for one video: every reader, every string
    /// through the recursive hub, the rules over every leaf, then the
    /// existing-tag pass over what survives.
    ///
    /// One deadline spans the WHOLE item — readers' strings share the
    /// budget, so a pathological sidecar cannot starve the metadata pass
    /// of its turn only by being listed first... it can, but the run says
    /// so via `truncated` instead of hanging.
    public func analyzeItem(
        _ itemID: UUID,
        rules: [RuleEngine.Rule],
        readers: [any AnalysisReader]? = nil,
        fileAccess: any FileAccess = LiveFileAccess(),
        deadline: ParseDeadline = .seconds(5)
    ) throws -> ItemAnalysis {
        guard let item = try writer.read({ try MediaItem.fetchOne($0, key: itemID) }) else {
            return .empty
        }
        let fileURL = try? resolvedFileURL(for: item, fileAccess: fileAccess)

        // JSON before Path: the precise detector before the loose one, or
        // every JSON payload containing a slash is shredded as a path.
        let parser = TextParser(subParsers: [
            JsonSubParser(),
            PathSubParser(mediaRoot: nil, rules: rules),
        ])

        // Gather, then parse. A reader that throws contributes nothing
        // rather than sinking the run: five sources of evidence must
        // degrade one at a time.
        var merged: [String: (candidate: ParsedCandidate, origins: [AnalysisOrigin])] = [:]
        // Which schema, if any, claimed each JSON key found in this
        // video's payloads. First matched schema wins a contested key —
        // schemas are ordered by name, so the winner is deterministic.
        let schemas = (try? jsonSchemas()) ?? []
        var schemaMappings: [String: (category: String, schemaName: String)] = [:]
        var matchedSchemaNames: [String] = []
        var order: [String] = []
        var md5s: [String] = []
        var provenance: [ProvenanceStep] = []
        var truncated = false

        var readerReports: [ReaderReport] = []
        for reader in readers ?? Self.defaultAnalysisReaders() {
            var readerError: String?
            let sources: [AnalysisSourceText]
            do {
                sources = try reader.read(item: item, fileURL: fileURL, library: self)
            } catch {
                sources = []
                readerError = "\(error)"
            }
            readerReports.append(ReaderReport(
                readerID: reader.id, displayName: reader.displayName,
                sources: sources, error: readerError))
            for source in sources {
                // The reader's key enters the walk at the top, so the
                // rule fold sees it exactly once — a keyed metadata value
                // and a JSON leaf take the same path through the engine.
                // A structured payload is checked against the KNOWN
                // schemas before parsing: a match turns the schema's key
                // mappings into suggestions for every leaf under those
                // keys.
                if !schemas.isEmpty {
                    // Whole-string JSON, or spans embedded in prose —
                    // each PAYLOAD is matched on its own key set.
                    let payloads: [String] = {
                        guard let effective = JsonLeafExtractor.effectiveJSONText(source.text)
                        else { return [] }
                        return JsonLeafExtractor.isStructuredJSON(effective.text)
                            ? [effective.text]
                            : JsonLeafExtractor.embeddedSpans(in: effective.text).map(\.json)
                    }()
                    for payload in payloads {
                    let payloadKeys = Set(
                        JsonLeafExtractor.extract(payload).compactMap(\.rawKey))
                    for schema in schemas where schema.matches(payloadKeys: payloadKeys) {
                        if !matchedSchemaNames.contains(schema.name) {
                            matchedSchemaNames.append(schema.name)
                        }
                        for (foldedKey, category) in schema.categoryByFoldedKey
                        where schemaMappings[foldedKey] == nil {
                            schemaMappings[foldedKey] = (category, schema.name)
                        }
                    }
                    }
                }
                let sourceLabel: String = {
                    if let file = source.sourceFile { return file }
                    if let key = source.key { return "\(reader.displayName) · \(key)" }
                    return reader.displayName
                }()
                let result = parser.parse(
                    source.text, key: source.key, rules: rules, deadline: deadline,
                    origin: [sourceLabel])
                truncated = truncated || result.truncated
                provenance += result.provenance
                for hash in result.md5s where !md5s.contains(hash) { md5s.append(hash) }

                for parsed in result.candidates {
                    let key = parsed.key
                    let folded = parsed
                    let value = folded.value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty else { continue }
                    let origin = AnalysisOrigin(
                        readerID: reader.id, timeSeconds: source.timeSeconds,
                        sourceFile: source.sourceFile)
                    let dedupeKey = "\(KeyNormalizer.normalize(key ?? ""))|\(value.lowercased())"
                    if var known = merged[dedupeKey] {
                        if !known.origins.contains(origin) { known.origins.append(origin) }
                        // A category from ANY occurrence wins over none.
                        if known.candidate.category == nil, folded.category != nil {
                            known.candidate = ParsedCandidate(
                                value: known.candidate.value, category: folded.category,
                                suppressedByRule: known.candidate.suppressedByRule, key: key,
                                trail: known.candidate.trail)
                        }
                        merged[dedupeKey] = known
                    } else {
                        merged[dedupeKey] = (
                            ParsedCandidate(
                                value: value, category: folded.category,
                                suppressedByRule: folded.suppressedByRule, key: key,
                                trail: folded.trail),
                            [origin])
                        order.append(dedupeKey)
                    }
                }
            }
        }

        // The existing-tag pass, over what survived.
        let inventory = try tagInventory()
        let appliedIDs = Set(try tags(of: itemID).flatMap(\.tags).map(\.id))
        var existing: [ExistingTagFinding] = []
        var existingSeen = Set<String>()
        var suggested: [AnalysisCandidate] = []
        var unmapped: [AnalysisCandidate] = []

        for dedupeKey in order {
            guard let entry = merged[dedupeKey] else { continue }
            // A rule's category wins over a schema's — rules are the
            // sharper instrument, and the schema is the net beneath them.
            var category = entry.candidate.category
            var mappedBySchema: String? = nil
            if category == nil, entry.candidate.suppressedByRule == nil,
               let key = entry.candidate.key,
               let mapping = schemaMappings[KeyNormalizer.normalize(key)]
            {
                category = mapping.category
                mappedBySchema = mapping.schemaName
            }
            let candidate = AnalysisCandidate(
                value: entry.candidate.value, key: entry.candidate.key,
                category: category,
                suppressedByRule: entry.candidate.suppressedByRule,
                mappedBySchema: mappedBySchema,
                trail: entry.candidate.trail,
                origins: entry.origins)

            if candidate.category != nil, candidate.suppressedByRule == nil {
                suggested.append(candidate)
                continue
            }
            // Ignore-ruled strings skip tag matching — that IS the
            // false-positive reduction — but stay listed below.
            if candidate.suppressedByRule == nil {
                for hit in Self.findTags(in: candidate.value, inventory: inventory) {
                    let finding = ExistingTagFinding(
                        tag: hit.tag, categoryName: hit.categoryName,
                        matchedText: hit.matchedText, foundIn: candidate.value,
                        alreadyApplied: appliedIDs.contains(hit.tag.id))
                    if existingSeen.insert(finding.id).inserted {
                        existing.append(finding)
                    }
                }
            }
            unmapped.append(candidate)
        }

        return ItemAnalysis(
            suggested: suggested.sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending },
            existing: existing.sorted {
                ($0.alreadyApplied ? 1 : 0, $0.tag.name) < ($1.alreadyApplied ? 1 : 0, $1.tag.name)
            },
            unmapped: unmapped,
            md5s: md5s, matchedSchemas: matchedSchemaNames,
            readerReports: readerReports,
            truncated: truncated, provenance: provenance)
    }

    // MARK: - The existing-tag pass

    struct TagNeedle: Sendable {
        let needle: String  // lowercased name or alias
        let matchedText: String
        let tag: Tag
        let categoryName: String
    }

    /// Every tag name and alias, lowercased, with its tag — the needles
    /// the existing-tag pass searches for.
    func tagInventory() throws -> [TagNeedle] {
        try writer.read { db in
            let categories = Dictionary(
                uniqueKeysWithValues: try TagCategory.fetchAll(db).map { ($0.id, $0.name) })
            let tags = try Tag.fetchAll(db)
            let byID = Dictionary(uniqueKeysWithValues: tags.map { ($0.id, $0) })
            var needles: [TagNeedle] = []
            for tag in tags {
                needles.append(TagNeedle(
                    needle: tag.name.lowercased(), matchedText: tag.name,
                    tag: tag, categoryName: categories[tag.tagCategoryID] ?? ""))
            }
            for alias in try TagAlias.fetchAll(db) {
                guard let tag = byID[alias.tagID] else { continue }
                needles.append(TagNeedle(
                    needle: alias.alias.lowercased(), matchedText: alias.alias,
                    tag: tag, categoryName: categories[tag.tagCategoryID] ?? ""))
            }
            return needles
        }
    }

    /// Word-boundary search for every needle inside one string. "taped by
    /// Mike Jones 2019" finds the tag "Mike Jones"; "Jonestown" does not.
    ///
    /// Needles under three characters are skipped — a two-letter tag
    /// name matching inside every third sentence is a false-positive
    /// storm, and a tag that short is findable by eye anyway.
    static func findTags(in text: String, inventory: [TagNeedle]) -> [TagNeedle] {
        let haystack = text.lowercased()
        var hits: [TagNeedle] = []
        var seenTags = Set<UUID>()
        for needle in inventory where needle.needle.count >= 3 {
            guard !seenTags.contains(needle.tag.id) else { continue }
            var searchRange = haystack.startIndex..<haystack.endIndex
            while let range = haystack.range(of: needle.needle, range: searchRange) {
                if isWordBounded(range, in: haystack) {
                    hits.append(needle)
                    seenTags.insert(needle.tag.id)
                    break
                }
                searchRange = range.upperBound..<haystack.endIndex
            }
        }
        return hits
    }

    /// Bounded when the characters just outside the match are not
    /// letters or digits — so a needle inside a longer word never hits.
    private static func isWordBounded(_ range: Range<String.Index>, in text: String) -> Bool {
        if range.lowerBound > text.startIndex {
            let before = text[text.index(before: range.lowerBound)]
            if before.isLetter || before.isNumber { return false }
        }
        if range.upperBound < text.endIndex {
            let after = text[range.upperBound]
            if after.isLetter || after.isNumber { return false }
        }
        return true
    }

    // MARK: - The basket

    /// Write the basket. Each pending tag either applies an existing tag
    /// or creates-then-applies by (trimmed) value — `ensureTag` reuses a
    /// same-named tag in the category, so accepting a suggestion whose
    /// value already names a tag applies rather than duplicates.
    /// Returns how many landed.
    @discardableResult
    public func commitPendingTags(_ pending: [PendingTag], to itemID: UUID) throws -> Int {
        var applied = 0
        for one in pending {
            if let tagID = one.existingTagID {
                try assignTag(tagID, to: itemID)
                applied += 1
                continue
            }
            let value = one.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            let tag = try ensureTag(named: value, inCategory: one.categoryID)
            try assignTag(tag.id, to: itemID)
            applied += 1
        }
        return applied
    }
}
