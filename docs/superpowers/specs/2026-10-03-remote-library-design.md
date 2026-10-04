# Remote library

*2026-10-03. A second Mac on the same network opens a library that lives on
this one: browse, watch, tag and manage, with nothing of the library stored
on the second Mac.*

## What was decided

These came from the design conversation and are not open:

- **The same app, not a second one.** A remote library is a row in the
  library picker; it opens the ordinary library window.
- **No local copy on the client.** Every read is a request the host
  answers. Revoking a client leaves it with nothing.
- **Tag and manage, not only watch.** Writes and jobs are in scope.
- **Nothing advertised.** No Bonjour, no mDNS. A client is given the
  host's address by a pairing code, as text or a QR.
- **Approved clients, encrypted traffic.** The host approves each client
  by hand; all traffic is TLS to a pinned certificate.
- **Same LAN only.** No access from outside the network.
- **The library is very large.** Nothing in the design may depend on
  moving the whole database.

## Not in this design

- Any device that is not a Mac running this app.
- Access from outside the LAN, relays, or accounts for other people.
- Transcoding on the host. A file the client Mac cannot play is reported
  by the player as it would be for a local file.
- Working while disconnected. A change made with no connection is not
  made, and the window says so; nothing is queued for later.
- Adding or removing sources, moving or restoring the library file, and
  the demo-library seeders, from a client.

## 1. The service boundary

The app target reaches the database three ways today (measured on `dev`
at `039122a`): 135 distinct `library.…(…)` methods, 40 raw GRDB closures
in 18 files, and 49 direct uses of `JobRunner`. None of it can cross a
wire, so the first half of this work is a refactor with no remote code in
it at all.

**`LibraryService`**, a protocol in the Kit. Every read and write the app
makes is a named operation on it, grouped by what needs it: browse (items
for a `MediaFilter`, counts, folder trees, vocabulary, saved filters),
item (details, tags, field values, segments, snapshots), player (resume
position, blocks, recognised text), tagging and fields, organise, review
and maintenance, import (scan a source, import a list), jobs (enqueue,
cancel, list), settings. Inputs and results are plain `Codable` values.
No GRDB type crosses the boundary. After the refactor the app target does
not name `LibraryDatabase` or `JobRunner`.

**`LocalLibraryService`** wraps `LibraryDatabase` and `JobRunner`. The 40
raw SQL sites move into it. It is what the app uses for a library it opens
itself, and its behaviour is today's behaviour.

**`RemoteLibraryService`** speaks HTTPS to a host: one endpoint per
operation, the same `Codable` values. The host side is an adapter that
decodes a request, calls `LocalLibraryService`, and encodes the result. The
host runs no logic that the local app does not.

**Changes** are part of the service: `changes`, an `AsyncStream` of
`LibraryChange`. Locally it is fed by `LibraryChangeHub`. Remotely it is
fed by one long-lived request on which the host writes the changed domains
whenever its hub delivers. `BrowseModel.libraryChanged` and the auxiliary
windows' change counts are unchanged.

**Order.** The protocol and `LocalLibraryService` first, with
`BrowseModel` moved onto them, then `PlayerModel`, then each auxiliary
window, one pull request each, each behaviour-neutral. Only then the
remote implementation, window by window. A window the remote service does
not cover yet shows "Not available for a remote library yet" rather than a
broken view.

## 2. Pairing and transport

**The host's identity.** Turning on remote access generates one
self-signed TLS identity (an EC key in the host's Keychain and a
long-lived certificate) and picks a port. The listener binds the LAN
addresses only. A connection without a valid device token is answered
"unauthorised" and nothing else: no library name, no version.

**The pairing code.** Host Settings shows a code, as text to copy and as a
QR, valid for ten minutes or one use. It carries the host's address and
port, the certificate's SHA-256 fingerprint, and a 128-bit one-time
secret. The client's "Connect to another Mac…" takes the pasted text; QR
scanning by camera may follow. The client connects, checks the server
certificate against the fingerprint before sending anything, then presents
the secret with its own name. The host asks "Allow 'Studio MacBook' to use
this library?", and only on a yes issues a 256-bit device token. The
fingerprint arrives with the code, so there is no trust-on-first-use gap.

**Tokens.** The client keeps its token in its Keychain, bound to the
host's fingerprint. The host stores a hash of each token with the device
name, approval date and last-seen time. **Approved Clients** in host
Settings lists them, each with Revoke. Revoke is immediate. Turning remote
access off stops the listener and keeps the approvals.

**Transport.** HTTPS only. One `URLSession` on the client whose delegate
enforces the pin: any other certificate is refused, including a valid
CA-signed one. Each request carries the token in a header, and the app
version; a host and client on different versions refuse each other with
"update the other Mac", because the service's values and the schema move
together.

**What the host enforces beyond the token.** Commands are validated as the
local app validates them, since the host is `LocalLibraryService`. File
bytes are served by item id, never by path, so no request can name an
arbitrary file.

All of this lives in a new target, `SightsAndSoundsRemote`. The Kit stays
free of it.

## 3. Commands, jobs and conflicts

**Writes are commands the host executes** through `LocalLibraryService`,
as if a window on the host had made them. The host's rules are the only
rules: a snapshot before a tag write, segments outliving their video, no
path outside a source, and the remove-from-library choice to write tags
first (the client asks, then sends the answer).

**Jobs run on the host.** Remux, repair, writeback, import, Media Signal
and removal need the host's drives and tools, so they go on the host's one
`JobRunner`. The client's Background Tasks shows the host's lane through
the service, with Cancel, Run next, Retry, Clear finished, Pause and
Resume sent as commands. The host's lane header says how many clients are
connected.

**Import** works remotely as locally: the host walks the source and
returns the `ScanOutcome`; the tree, the staged tags and the import are
requests. Adding a source is not offered from a client: a source is a
path on the host's disk.

**Conflicts.** Several windows already edit one library, last write wins
per row, and the change hub refreshes everyone. A remote client is one
more window, with latency. No locking is added. A command naming an item
the host has since removed returns "no longer in the library", shown as a
notice.

**Failures.** Host unreachable: a disconnected banner, the windows keep
what they showed, the client retries quietly, and no command is kept for
later. Token revoked: every request fails alike and the banner says so.
Host quit: the clients show "host closed the library".

**Not offered to a client:** adding or removing sources; the library
file's location, swap and restore; Reveal in Finder and Open With (shown
disabled, "not on this Mac"); the demo seeders.

## 4. Playback, thumbnails and the windows

**Playback.** `PlayerModel` asks the service for an item's playable URL.
Locally it is the file. Remotely it is a loopback relay inside the client:
`AVPlayer` cannot pin a certificate, so it plays
`http://127.0.0.1:<port>/item/<id>` and the relay forwards its range
requests over the pinned, tokened connection. The host serves the file's
bytes as they are. Seeking, scrubbing and segments work because range
requests work. Nothing crosses the LAN unencrypted.

**Thumbnails** are served by item id and cached on the client, in memory
and under the caches directory, keyed by host fingerprint, item id and the
host's thumbnail stamp. Scrub previews are generated on the client through
the relay. The caches hold images only and can be cleared.

**The client.** The library picker gains a **Remote** list under the
local libraries: one row per paired host. "Connect to another Mac…" starts
pairing. A remote library's window title ends "on ‹host name›", and the
sidebar footer shows the connection: connected, reconnecting, revoked.

**The host.** Settings gains **Remote Access**: the switch, the port, the
current pairing code with its countdown and "New code", and Approved
Clients.

## 5. Testing

- **The refactor** is proven by the existing suite after each model moves,
  plus one test per raw query moved into the Kit, asserting the rows the
  view used to get.
- **A contract suite** runs the same assertions through
  `LocalLibraryService` and through `RemoteLibraryService` pointed at an
  in-process host over loopback TLS, and requires equal results. This is
  what makes "the host runs no logic the local app does not" a tested
  claim.
- **Pairing and transport:** the code's encoding and expiry; a server with
  another certificate refused before any request; a revoked token failing
  every operation; a version mismatch refused with its message. The
  in-process host uses a real listener and a generated identity.
- **The relay:** a `DemoMediaFactory` file played through `AVPlayer`,
  with a seek, and the requests seen by the host checked for the token.
- **Commands:** applied through the remote service, then the host's
  database read directly and compared with what the local action writes,
  guards included. Jobs: enqueued, watched and cancelled remotely.
- **Not testable from `swift test`:** two real Macs. Each pull request's
  "After merging" gives the steps, with the Design Preview library on the
  host and never a real one.

## 6. Order of work

1. `LibraryService` and `LocalLibraryService`, with Browse on them
   (several pull requests: listing and counts, vocabulary and filters,
   tagging).
2. The player, then each auxiliary window.
3. A spike, kept nowhere: a listener with a generated identity and a
   pinned `URLSession` over loopback, and `AVPlayer` seeking through a
   loopback relay. It answers whether to write the HTTP handling by hand
   on `Network.framework` or take a small server dependency.
4. `SightsAndSoundsRemote`: identity, pairing code, token store, listener,
   Approved Clients, the host Settings pane. No client yet.
5. `RemoteLibraryService` for Browse reads and the change stream; the
   picker's Remote list; connecting.
6. The relay, playback and thumbnails.
7. Commands: tagging, fields, review, removal; then jobs and Background
   Tasks; then import.
8. Version mismatch, disconnected states, revocation.

Steps 1 and 2 are most of the work and stand on their own: they finish
moving the app's SQL into the Kit whether or not a client ever ships.

## Risks

- **The size of step 1.** 135 operations is a wide protocol. It is
  grouped by window so that each pull request moves one group, and no
  window is half-moved on `dev`.
- **Latency in the grid.** A listing is one request per page of items, as
  it is one query today; faceted counts and folder trees are separate
  requests. If scrolling stutters on a very large library, the remedy is
  paging and prefetch in `RemoteLibraryService`, not a local copy.
- **`AVPlayer` through a relay** is the least certain piece, which is why
  the spike comes before any remote code is kept.
