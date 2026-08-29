# 06 — Background tasks

**Comp:** `Mac Background Tasks.dc.html`
**Swift:** `BackgroundTasksView.swift`, `Jobs/JobRunner.swift`, `Jobs/JobRecord.swift`,
`SightsAndSoundsApp.swift` (`tasksPaused` ~140, `runner(for:)` ~152)

## What changes

The view is already right about the two things that matter: it groups by library (one
`JobRunner` per library, one job at a time each), and it reads `JobRecord.summary` rather
than re-deriving what a job did. `displayName` already maps all sixteen job kinds to human
names — **do not write a second mapping.**

Three additions: a lane per library above the table, a detail inspector beside it, and
per-lane pause. Plus tokens.

## Decisions

1. **One lane per library, because that is what the runner is.** Three open libraries means
   three queues that cannot race. The lane cards lift each library's *currently running* job
   out of the chronological list, so the state of the machine reads at a glance; the table
   below stays one chronological stream across all libraries, which is how you answer "what
   happened at 9:14".

2. **A lane's queue depth and whether it is running are two facts.** A lane with a live job
   must never read `idle` because its queue is empty. The card shows queue depth on the
   header row and the running job on the line below — `no job running` / `no queue` are
   different strings for a reason.

3. **Pause is per lane as well as global.** `JobRunner.setPaused` is already per runner;
   `AppModel.setTasksPaused` fans out to all of them. Expose both: pause one library's
   hashing sweep while another finishes an import. Pausing lets the **running job finish its
   current item** rather than tearing it down mid-write — say so in the button's help and in
   the banner, because the difference matters to anyone watching a write-back.

4. **Progress is derived from the clock, and the clock banks paused spans.** Store
   `startedAt` and derive elapsed; when a lane pauses, bank the span and subtract it. A
   paused lane's bar **freezes where it reached** and resumes from there. (Three separate
   timer bugs in this project came from ticking counters — see the tokens file, layout rule
   4.) `JobRecord` already carries `createdAt`, `startedAt`, `finishedAt`,
   `progressCurrent`, `progressTotal`; nothing needs to be invented.

5. **Keep the paused banner as visible state.** It exists in the current view via
   `safeAreaInset`, and it is correct: a toggled toolbar button is not state anybody notices
   three minutes later.

6. **A failed job keeps its evidence.** The inspector shows kind (human name *and* the raw
   `kind` identifier in mono, because that string is what you grep the log for), summary,
   a created/started/finished timeline, the payload, and the error in full — not the
   one-line truncation the row shows. Retry becomes a decision instead of a guess. The
   read-only-volume write-back is the case that proves it: 312 of 540 written, and a retry
   resumes rather than repeats.

7. **Actions follow state, and stay visible when unavailable** (shared decision §2). Running
   → Cancel. Queued → Run next, Remove from queue. Failed or cancelled → Retry, Copy error.
   Succeeded → Run again.

8. **Colour by family, not by state — state has its own column.** Ingest `#6FBFB0`,
   duplicates `#C58BB8`, operations `#8B93E8`, write-back `#E9A23B`, validation `#9DBF7F`,
   derived from the kind's prefix. The state pill carries the status hue. Two encodings of
   the same fact in one row is the mistake; two different facts is not.

9. **An empty window is the healthy state.** `No Background Tasks` currently reads like a
   missing feature. `Nothing here` / `Workers sleep until there is work. This is the normal
   state.` says the true thing.

10. **Run next reorders the queue; it never interrupts.** A queued job can be pushed to the
    front of its library's lane, and that is the only ordering control — no pause-this-and-run
    that. The runner is serialized on purpose, and a job mid-write finishes. So the toast says
    what actually happened: `Moved to the front of this library's queue`, not "running now".

## Model changes

| Change | Why | Where |
|---|---|---|
| `deleteFinished()` — drop `succeeded`/`cancelled` records | "Clear finished" has nothing to call. Failed rows survive it; their evidence is the point. | `Jobs/JobRunner` |
| `retry(_ jobID:)` — re-enqueue the same kind and payload as a new record | Retrying must not rewrite history: the failure stays in the list, the retry is a new row. | `Jobs/JobRunner` |
| `priority: Int` on `JobRecord` (default 0), `ORDER BY priority DESC, createdAt` in the queue read | "Run next" needs somewhere to write. **Decided Aug 2026: build it.** Run next sets the priority above the current maximum among queued rows rather than to a fixed number, so two Run nexts in a row keep their relative order. Priority never pre-empts a *running* job — the runner is serialized, and a job that is already writing finishes. | `Jobs/JobRecord`, `JobRunner.runPending` |
| Per-runner paused state readable from the view | The lane's Pause/Resume needs the truth per library, not the app-wide flag. | `Jobs/JobRunner` |

Job **history retention** is unbounded today — `limit(30)` in the view is a display cap, not
a policy. Decide it somewhere: trim `succeeded` records older than N days on library close,
where the cached summary is already being written (`01`, model change).

## Layout

Window `1240 × 838`. Toolbar: state segmented control (**All / Active / Failed / Finished**),
a mono headline count, **Clear finished**, **Pause all workers**. Paused banner below it on
`#2A2118` with a `#4A3C24` rule.

Lane cards, one row, `#151209` on a `#4A3C24` border while running: status dot (amber and
pulsing when live, grey when paused, `#3A3328` when idle), library name, queue depth, per-lane
Pause; then the running job's human name with its raw kind in mono, a 5 pt striped bar, and
`<current> of <total>` with a percentage.

Table columns `22 / 1fr / 132 / 118 / 92 / 116` — icon, job (name over summary), library,
progress, elapsed, state + Cancel. Header and body **both** get
`scrollbar-gutter: stable` (tokens, layout rule 1) or the columns come apart. Selected row
`#241E16` with `inset 2px 0 0 #E9A23B`.

Inspector 322 pt: kind, what it is doing, timeline, error block on `#0F0C07` with a
`#3E2A22` border, payload block, then the state's actions stacked full-width.

## Copy — verbatim

| Element | String |
|---|---|
| Filters | `All` · `Active` · `Failed` · `Finished` |
| Headline | `<n> running · <n> queued · <n> failed` |
| Pause buttons | `Pause all workers` / `Resume all workers` · lane: `Pause` / `Resume` |
| Paused banner | `Background tasks are paused — queued work waits, the running job finishes.` *(existing)* |
| Pause help | `Hold the queues — the running job finishes, nothing new starts` *(existing)* |
| Pause toast | `Workers paused — running jobs finish their current item first` |
| Lane, idle | `no job running` · `waiting for work` · `no queue` |
| Cancel toasts | `Cancelling after the current item` / `Removed from the queue` |
| Clear finished | `Finished jobs cleared from the list` |
| Inspector actions | `Cancel job` · `Run next` · `Remove from queue` · `Retry` · `Copy error` · `Run again` |
| Run next toast | `Moved to the front of this library's queue` |
| No selection | `Select a job to see its timeline, payload and any error.` |
| Empty | `Nothing here` / `Workers sleep until there is work. This is the normal state.` |
| Job names | `Import` · `Content hashing` · `Thumbnail generation` · `Duplicate check (hashes)` · `Audio fingerprinting` · `Duplicate check (fingerprints)` · `Clip export` · `Remux` · `Encode` · `Block removal` · `Text scan (OCR)` · `Join` · `Reorganize` · `Tag write-back` · `Tag restore` · `Validation` *(all existing — `displayName`)* |

## Keep from the existing view

`displayName`'s kind → name table, used as the only source of job labels anywhere in the app
(the tasks window, import history, and any toast that names a job). The per-library reads
awaiting **off the main actor** — polling every registered library once a second must not
stutter when one of them sits on a sleeping disk. The 1-second refresh loop cancelled with
the task. Summaries and errors rendered straight from the record. Cancellation through
`runner.requestCancel`, which is cooperative — the job checks it, and that is why "after the
current item" is the honest wording.
