import Foundation
import GRDB
import Testing

@testable import SightsAndSoundsKit

/// Every Media Signal sample, generated with ffmpeg and read by the stages
/// it was built for, each reading held to the truth the sample was made
/// with.
///
/// Opt-in: it makes about fifty files and decodes them, minutes of work.
///
///     SAS_SIGNAL_SAMPLES=1 swift test --filter SignalSampleCorpusTests
///
/// Every reading and every truth, with what was read against it, goes to
/// a SQLite report (`SAS_SIGNAL_SAMPLES_REPORT`, or `signal-samples.sqlite`
/// in the temporary folder) — the way to see where the analysis stands.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SAS_SIGNAL_SAMPLES"] != nil))
struct SignalSampleCorpusTests {
    static let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("sas-signal-samples", isDirectory: true)

    static let report: DatabaseQueue? = {
        let path = ProcessInfo.processInfo.environment["SAS_SIGNAL_SAMPLES_REPORT"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("signal-samples.sqlite").path
        try? FileManager.default.removeItem(atPath: path)
        guard let queue = try? DatabaseQueue(path: path) else { return nil }
        try? queue.write { db in
            try db.execute(sql: """
                CREATE TABLE reading (sample TEXT, topic TEXT, stage TEXT, key TEXT, scope TEXT, value REAL, declared TEXT);
                CREATE TABLE truth (sample TEXT, topic TEXT, key TEXT, expected TEXT, actual TEXT, held INTEGER, knownGap TEXT);
                CREATE TABLE failure (sample TEXT, stage TEXT, message TEXT);
                """)
        }
        return queue
    }()

    /// How many samples are made and read at once. Each one runs ffmpeg
    /// and then decodes; all fifty together swamped the machine.
    static let width = 3

    @Test func theReadingsMatchWhatEachSampleWasMadeWith() async throws {
        let ffmpeg = try #require(FfmpegTool.path(), "ffmpeg is needed to make the samples")
        var pending = SignalSamples.all[...]
        try await withThrowingTaskGroup(of: [String].self) { group in
            func startNext() {
                guard let sample = pending.popFirst() else { return }
                group.addTask { try await Self.check(sample, ffmpeg: ffmpeg) }
            }
            for _ in 0..<Self.width { startNext() }
            while let problems = try await group.next() {
                for problem in problems {
                    if problem.hasPrefix("KNOWN: ") {
                        withKnownIssue(Comment(rawValue: problem)) { Issue.record(Comment(rawValue: problem)) }
                    } else {
                        Issue.record(Comment(rawValue: problem))
                    }
                }
                startNext()
            }
        }
    }

    /// Make one sample, read it, and return what did not hold.
    static func check(_ sample: SignalSample, ffmpeg: String) async throws -> [String] {
        var problems: [String] = []
        let url: URL
        do {
            url = try SignalSamples.write(sample, into: folder, ffmpeg: ffmpeg)
        } catch {
            try? await report?.write { db in
                try db.execute(
                    sql: "INSERT INTO failure VALUES (?, 'make', ?)", arguments: [sample.id, "\(error)"])
            }
            return ["\(sample.id): could not be made: \(error)"]
        }

        var findings = SignalFindings()
        for stage in SignalStages.all where sample.stages.contains(stage.name) {
            do {
                let found = try await stage.examine(SignalStageInput(url: url, kind: sample.kind))
                findings.merge(found)
                try await report?.write { db in
                    for (key, value) in found.declared {
                        try db.execute(
                            sql: "INSERT INTO reading VALUES (?, ?, ?, ?, 'declared', NULL, ?)",
                            arguments: [sample.id, sample.topic.rawValue, stage.name, key, value])
                    }
                    for measured in found.measured where measured.scope != .frame && measured.scope != .window {
                        try db.execute(
                            sql: "INSERT INTO reading VALUES (?, ?, ?, ?, ?, ?, NULL)",
                            arguments: [sample.id, sample.topic.rawValue, stage.name, measured.key,
                                        "\(measured.scope)", measured.value])
                    }
                }
            } catch {
                try? await report?.write { db in
                    try db.execute(
                        sql: "INSERT INTO failure VALUES (?, ?, ?)",
                        arguments: [sample.id, stage.name, "\(error)"])
                }
                problems.append("\(sample.id): \(stage.name) failed: \(error)")
            }
        }

        for truth in sample.truths {
            let (key, expected, actual, held) = judge(truth, findings)
            try? await report?.write { db in
                try db.execute(
                    sql: "INSERT INTO truth VALUES (?, ?, ?, ?, ?, ?, ?)",
                    arguments: [sample.id, sample.topic.rawValue, key, expected, actual, held, gapReason(truth)])
            }
            if let problem = problem(sample.id, truth, key: key, expected: expected, actual: actual, held: held) {
                problems.append(problem)
            }
        }
        return problems
    }

    static func judge(_ truth: SignalSample.Truth, _ findings: SignalFindings)
        -> (key: String, expected: String, actual: String, held: Bool)
    {
        switch truth {
        case .declared(let key, let value):
            let read = findings.declared[key]
            return (key, value, read ?? "absent", read == value)
        case .measured(let key, let range):
            let read = reading(key, findings)
            let shown = read.map { String(format: "%.4g", $0) } ?? "absent"
            return (key, "\(range.lowerBound)…\(range.upperBound)", shown, read.map(range.contains) ?? false)
        case .withheld(let key):
            // Absent only counts when the stage read that family at all: a
            // renamed stage or key must not pass every "withheld" by default.
            let family = key.split(separator: ".").first.map(String.init) ?? key
            let familyRead = findings.measured.contains { $0.key.hasPrefix(family + ".") && $0.key != key }
            let read = reading(key, findings)
            let shown = read.map { String(format: "%.4g", $0) } ?? (familyRead ? "withheld" : "no \(family).* readings at all")
            return (key, "withheld", shown, read == nil && familyRead)
        case .evidence(let key, let range):
            let strength = SignalEvidenceRules.evidence(from: SignalFacts(findings: findings))
                .first { $0.key == key }?.strength ?? 0
            return (key, "\(range.lowerBound)…\(range.upperBound)", String(format: "%.2f", strength),
                    range.contains(strength))
        case .concluded(let category, let range):
            let confidence = SignalInferenceRules.conclude(SignalFacts(findings: findings)).conclusions
                .first { $0.category == category }?.confidence ?? 0
            return (category, "\(range.lowerBound)…\(range.upperBound)", String(format: "%.2f", confidence),
                    range.contains(confidence))
        case .gap(let inner, _):
            return judge(inner, findings)
        }
    }

    /// A reading at the scope the stage keeps it: the file's own value,
    /// else the high percentile (detail: the best the file can do), else
    /// the median (what it usually does).
    static func reading(_ key: String, _ findings: SignalFindings) -> Double? {
        findings.value(key, .file) ?? findings.value(key, .high) ?? findings.value(key, .median)
    }

    static func gapReason(_ truth: SignalSample.Truth) -> String? {
        if case .gap(_, let reason) = truth { return reason }
        return nil
    }

    /// What a verdict has to say, if anything. A gap that now holds has
    /// been closed: that is said too, so the truth is promoted rather than
    /// left looking unreached (a closed gap used to pass silently).
    static func problem(
        _ sample: String, _ truth: SignalSample.Truth, key: String, expected: String, actual: String, held: Bool
    ) -> String? {
        let message = "\(sample): \(key) should be \(expected), read \(actual)"
        if case .gap(_, let reason) = truth {
            return held
                ? "\(sample): \(key) is marked a known gap (\(reason)) but now holds — make it a plain truth"
                : "KNOWN: \(message) — \(reason)"
        }
        return held ? nil : message
    }
}

/// The corpus's verdicts, without making any files.
@Suite struct SignalSampleVerdictTests {
    @Test func aClosedGapIsReportedAndAnOpenOneIsKnown() {
        let gap = SignalSample.Truth.gap(.withheld("audio.lineWhistleHz"), "why")
        let closed = SignalSampleCorpusTests.problem("s", gap, key: "k", expected: "e", actual: "a", held: true)
        #expect(closed?.contains("now holds") == true)
        #expect(closed?.hasPrefix("KNOWN: ") == false)
        let open = SignalSampleCorpusTests.problem("s", gap, key: "k", expected: "e", actual: "a", held: false)
        #expect(open?.hasPrefix("KNOWN: ") == true)
        let plain = SignalSample.Truth.withheld("audio.lineWhistleHz")
        #expect(SignalSampleCorpusTests.problem("s", plain, key: "k", expected: "e", actual: "a", held: true) == nil)
        #expect(SignalSampleCorpusTests.problem("s", plain, key: "k", expected: "e", actual: "a", held: false) != nil)
    }
}


/// Making the samples library: never over an existing file, and a failed
/// run leaves nothing behind, so it can simply be tried again.
@Suite struct SignalSamplesLibraryTests {
    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-samples-lib-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func aFailedRunLeavesNoLibraryFile() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Signal Samples.sqlite")
        // A tool that is not there: the first sample fails.
        await #expect(throws: (any Error).self) {
            try await SignalSamples.makeLibrary(
                at: url, mediaFolder: dir.appendingPathComponent("Media"), ffmpeg: "/nonexistent/ffmpeg")
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("Signal Samples.sqlite") }
        #expect(left.isEmpty, "left behind: \(left)")
    }

    @Test func anExistingLibraryIsNeverOpened() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Signal Samples.sqlite")
        let existing = try LibraryDatabase.open(at: url)
        try existing.ensureInfo(name: "Someone else's")
        await #expect(throws: LibraryCreationError.fileExists(url.lastPathComponent)) {
            try await SignalSamples.makeLibrary(
                at: url, mediaFolder: dir.appendingPathComponent("Media"), ffmpeg: "/nonexistent/ffmpeg")
        }
        #expect(try existing.info()?.name == "Someone else's")
    }
}

/// Always on, no ffmpeg needed: the opt-in corpus cannot rot unseen. Every
/// stage a sample names must be a real stage — a renamed one was skipped
/// without a word — and it must be one that reads the sample's kind.
@Suite struct SignalSampleCatalogTests {
    @Test func everySampleNamesRealStagesForItsKind() {
        let stages = Dictionary(uniqueKeysWithValues: SignalStages.all.map { ($0.name, $0) })
        for sample in SignalSamples.all {
            #expect(!sample.stages.isEmpty, "\(sample.id) runs no stage")
            for name in sample.stages {
                guard let stage = stages[name] else {
                    Issue.record("\(sample.id) names a stage that does not exist: \(name)")
                    continue
                }
                #expect(stage.kinds.contains(sample.kind), "\(sample.id): \(name) does not read \(sample.kind)")
            }
            #expect(!sample.truths.isEmpty, "\(sample.id) holds no truth")
        }
        #expect(Set(SignalSamples.all.map(\.id)).count == SignalSamples.all.count, "two samples share an id")
    }
}

