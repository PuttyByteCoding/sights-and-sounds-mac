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
            if !held {
                let message = "\(sample.id): \(key) should be \(expected), read \(actual)"
                if case .gap(_, let reason) = truth {
                    problems.append("KNOWN: \(message) — \(reason)")
                } else {
                    problems.append(message)
                }
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
            let read = reading(key, findings)
            return (key, "withheld", read.map { String(format: "%.4g", $0) } ?? "withheld", read == nil)
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
}

