# 15 — Devices

**Comp:** `Mac Devices.dc.html`
**Swift:** net-new. Nothing in the repo serves, pairs or authorises anything today.

This is the Phase 9 surface for the platforms that follow the Mac. The Mac is the host — it
owns the library files; iOS, iPadOS and tvOS reach them over the local network. Library
creation and configuration stay Mac-only on every platform rev, so this window grants access
to what already exists; it never creates it.

## Decisions

1. **Pairing is not access.** A newly paired device arrives with **every library set to None**
   and reads as *Requesting access* until a role is granted here. It cannot see that a library
   exists — not the name, not the item count. Approving a device and choosing what it may
   reach are two decisions, and collapsing them is how a guest phone ends up listing Home
   Videos.

2. **A device is the identity.** No accounts, no identity provider, nothing that reaches the
   internet. Pairing puts a long-lived token in the device's Keychain, and revoking that token
   is the entirety of removing access — there is no user record to also disable, and no
   password anywhere.

3. **Pinned, not trusted.** The Mac holds one self-signed identity; the device pins its
   fingerprint at pairing and refuses anything else afterwards. That replaces a certificate
   authority and the per-device trust dance, and it means **nothing has to be installed on any
   client**. Show the fingerprint on both ends and make the operator compare them — that
   comparison is the whole security model, so it gets the space.

4. **One certificate is one identity.** A certificate already pinned is the same device coming
   back: pairing again **refreshes** it and keeps its roles rather than creating a second row.
   That is precisely what makes revocation sufficient — if a re-pair could mint a second
   identity, revoking the first would mean nothing.

5. **Roles are per library, not per device.** The living-room Apple TV can hold Concerts and
   Home Videos and never see Learning. Four roles: **None** (not listed at all) · **Viewer**
   (browse and play) · **Editor** (browse, play, edit tags) · **Full** (everything the platform
   supports).

6. **A platform ceiling is shown, not hidden.** tvOS has no editing surface, so its highest
   role is Viewer — Editor and Full appear **struck through and disabled** with an explanation
   on click, not removed. Shared decision §2: unavailable, not hidden. A missing option teaches
   nothing about why it is missing.

7. **Serving is a visible state with a stated consequence.** Stopping advertisement does not
   revoke anything: paired devices keep their tokens and reconnect when serving resumes. Say
   that on the toggle, or stopping will be mistaken for revoking — and revoking for a pause.

8. **A pairing code expires, and the countdown is derived from a clock.** 90 seconds, computed
   from `startedAt` rather than ticked down, so a re-render cannot strand it (tokens file,
   layout rule 4). Regenerating is one button.

## What has to be built

| Piece | Notes |
|---|---|
| Bonjour advertisement (`_sightsandsounds._tcp`) | Advertise while serving; stop cleanly. |
| Self-signed identity in the Mac's Keychain | One per host, generated on first serve, fingerprint displayed. |
| Pairing: short-lived numeric code + QR of the same payload | Phones scan; tvOS types. The code authorises exactly one pairing. |
| `PairedDevice`: name, platform, certificate fingerprint (unique), token, pairedAt, lastSeenAt, platform capability ceiling | Fingerprint is the identity key — §4 depends on its uniqueness. |
| `DeviceLibraryRole`: device × library → none/viewer/editor/full | §5. Absence means none. |
| Request authorisation: every request checks token, then role, then the guard function for the operation | Shared decision §4 — the guard lives in the query, and a remote request is just another caller. |

A remote client must go through the **same** scoping functions as the local UI. A role check
that only the network layer applies is a second implementation of the rule, and the second one
is the one that will be forgotten.

## Layout

Window `1260` wide. Serving strip across the top: pulsing green dot when advertising, the
service name and paired count in mono, **Stop serving**, and the primary **Pair a device…**
(inert while not serving).

**Device rail**: the host first (`host · owns the libraries`), then paired devices — platform
icon, name, and a meta line that is one of *requesting access* (amber, pulsing dot), *online*,
or *last seen …*. Selected row `#2A2118` with the amber inset.

**Detail**: large icon, name, platform, then a facts block — Status, Paired, **Pinned
certificate** (mono, truncated), Token (`in this device's Keychain`). A device awaiting access
gets an amber note above the roles. Then one row per library: name, the four-way segmented
role, and a one-line consequence beneath the current choice. **Revoke** at the foot, using the
neutral-but-irreversible treatment (`#2A241C`, not red — nothing is destroyed).

**Pairing sheet**: the six-digit code at display size with its countdown and **New code**, the
QR beside it; once a device answers, it swaps to the fingerprint comparison — device name,
platform, IP, and the fingerprint in mono across two lines of sixteen bytes. Confirm is the
primary; the note differs for a known certificate.

## Copy — verbatim

| Element | String |
|---|---|
| Serving, on | `Advertising on the local network` / `_sightsandsounds._tcp · <Host> · <n> devices paired` |
| Serving, off | `Not advertising` / `Paired devices keep their tokens and reconnect when you start serving again` |
| Serving toggles | `Stop serving` · `Start serving` · `Pair a device…` |
| Serving toasts | `Stopped advertising — paired devices cannot reach this Mac` · `Advertising over Bonjour` |
| Rail meta | `host · owns the libraries` · `requesting access` · `online · viewer only` · `last seen <when>` |
| Facts | `Status` · `Paired` · `Pinned certificate` · `Token` / `in this device's Keychain` |
| Awaiting access | `<Device> has paired and is trusted, but no library has been granted to it. Until you set a role below it cannot see that any library exists — not their names, not their counts.` |
| Roles blurb | `Set per library, not per device. A role of None means the library is not listed at all on that device.` |
| Roles blurb, capped | `This platform never edits, so its highest role is Viewer — it can be given a library or denied one, and nothing more.` |
| Role consequences | `not listed on this device` · `browse and play` · `browse, play and edit tags` · `everything this platform supports` |
| Capped role click | `tvOS is paired as a viewer — it has no editing surface` |
| Pair, waiting | `Pair a device` / `Open Sights and Sounds on the device, pick this Mac, and enter the code. Phones can scan the square instead.` |
| Pair, answered | `A device is asking to pair` / `Check the fingerprint shown on the device against this one before pairing.` |
| Fingerprint, new | `The device shows this same fingerprint. If they match, it pins ours and will refuse anything else from then on — no trust store, on any platform.` |
| Fingerprint, known | `This certificate is already pinned to <Device>. Pairing again refreshes that device rather than creating a second one — one certificate is one identity, which is what makes revoking it sufficient.` |
| Paired | `<Device> paired — it has no access to any library yet` |
| Reconnected | `<Device> reconnected — its roles are unchanged` |
| Revoked | `<Device> revoked — its token no longer authorises anything` |
