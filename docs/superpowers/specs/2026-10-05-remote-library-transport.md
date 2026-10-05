# Remote library: the transport, after the spike

*2026-10-05. Amends `2026-10-03-remote-library-design.md`. Sections 1, 3 and 5
of that document stand. Section 2 (pairing and transport) is replaced by this
one, section 4's relay is confirmed, and the order of work is revised.*

## What the spike asked, and what it found

The spike was two throwaway tests. Its code is not kept.

**Can the two Macs talk over an encrypted, authenticated channel with what
macOS ships?** Yes, but not the way the first design said.

- The first design was TLS to a self-signed certificate, pinned, with the
  host's key in the Keychain. Two facts sink it for this app. There is no
  public way on macOS to make a TLS identity from a key held in memory: it
  has to come out of a keychain. And this app is built unsigned, and rebuilt
  often; a keychain item is tied to the binary that made it, so the system
  would ask permission again after every rebuild.
- **TLS with a pre-shared key** needs neither a certificate nor a keychain,
  and `Network.framework` supports it. Apple's own sample for pairing two
  devices on a local network uses it.
- On loopback: the right key connects; a wrong key is refused at the
  handshake ("bad MAC"); a key name the host does not know is refused
  ("unknown PSK identity"); a client that does not speak TLS gets an alert
  and nothing else.
- **Forward secrecy is available.** Of the pre-shared-key suites,
  `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256` (0xCCAC) is really
  negotiated. Several others that can be asked for are not supported and
  **fall back without saying so** to a suite with no forward secrecy. So
  both ends check which suite was negotiated and drop the connection if it
  is not the one asked for.
- TLS 1.3 does not work with a pre-shared key here. The channel is TLS 1.2.
- The host can see that a connection used *one of* its keys, not which. So
  who is calling is said inside the channel, in the first message.

**Does `AVPlayer` play, and seek, through a relay on the client?** Yes. Given
`http://127.0.0.1:<port>/…` served by a plain listener bound to loopback, it
loaded, seeked exactly to 4.0 s, played on, and `AVAssetImageGenerator` took a
frame through the same URL. It asks for bytes 0–1 first, then real ranges, and
needs `206`, `Content-Range`, `Accept-Ranges`, `Content-Length` and a correct
`Content-Type`.

## The transport

**No dependency is added.** The listener, the connection, the framing and the
relay are `Network.framework` and Foundation.

**The channel.** TCP, TLS 1.2, pre-shared key, suite 0xCCAC, verified after
the handshake on both ends. The key is 32 random bytes, one per paired device.
The host's listener carries every approved device's key; a device's key is the
only thing that completes a handshake with it.

**Not HTTP.** Both ends are this app, so between the Macs the messages are
frames: a four-byte length, a one-byte kind, the bytes. Requests and answers
are the `Codable` values of `LibraryService`, as JSON; a large answer is
compressed. A connection carries one request at a time; the client keeps a
small pool of them, with one set aside for the library's change stream and
the rest shared by requests and media. HTTP is spoken only on the client's
own loopback, by the relay, to `AVPlayer`.

**The first message.** Every connection opens with who is calling: the
protocol version, the library schema the client was built for, the device's
id and its token. The host answers with its name and the libraries it offers,
or refuses and closes: unknown device, revoked, or a version the two do not
share ("update the other Mac"). Nothing else is answered before that.

**The address.** The host listens on a port it chose, and takes a connection
only from an address on a private network (10/8, 172.16/12, 192.168/16,
link-local, and the IPv6 equivalents) or from the Mac itself. Loopback is
taken because it costs nothing in safety — a caller there still needs a
key — and it is how both ends are tried on one Mac. Nothing is advertised.

## Pairing

1. On the host, **Pair a Device** makes a one-time secret (32 random bytes)
   and shows a **pairing code**: text to copy, and the same as a QR. The code
   carries the host's address and port, its name, and the secret. It is good
   for ten minutes and for one device. While it is live, the listener also
   accepts the secret as a key.
2. On the client, **Connect to another Mac…** takes the code. The client
   connects with the secret as its key, and says its own name.
3. The host asks: *Allow "Studio MacBook" to use this Mac's libraries?* Only
   on a yes does it make that device a key and a token of its own and send
   them back down the channel. The pairing secret stops working at once.
4. The client keeps the host's address, its own device id, key and token.
   From then on it connects with its own key.

The code is long because it has to be: a pre-shared key that a person could
type would be one an eavesdropper could guess from a recorded handshake. It is
a secret for ten minutes. Anyone who sees it in that time can ask to pair, and
the host still has to say yes to the name it shows.

**Approved devices** are listed in the host's Settings with their name, when
they were approved and when they last connected, each with **Revoke**. Revoke
refuses the device's token at once and rebuilds the listener without its key.
Turning remote access off stops the listener and keeps the approvals.

## Where the secrets are

In files, not the Keychain, for the reason above: on the host, each device's
key and a hash of its token; on the client, each host's address with the
device's key and token. The files are in the app's own support folder,
readable only by the user (mode 0600). This is weaker than the Keychain
against other software running as the same user, and is the honest choice
while the app is unsigned. If the app is ever signed, moving them is a change
to one type.

## What is protected, and what is not

- Traffic between the Macs is encrypted and authenticated in both directions,
  with forward secrecy: a key stolen later does not open traffic recorded
  earlier.
- A device that is not paired, or is revoked, gets no answer.
- A paired device can do what the app can do with the library. There are no
  finer permissions, as before.
- The relay listens on loopback only. Its URLs carry a random token per
  session, so another program on the client Mac cannot read a video by
  guessing an item's id.
- Not protected: the library against someone who has the user's account on
  either Mac.

## Order of work, revised

The first design moved every window onto the service before any remote code.
Browse and the player are moved; the rest are not. The remote side is built
next for those two, because the transport and a very large listing over a
network are the parts most likely to change the design, and are better met
before another twenty refactors than after.

1. *(done)* `LibraryService`, with Browse and the player on it.
2. *(done)* Where an item's file is.
3. *(done)* The spike.
4. `SightsAndSoundsRemote`: frames, the channel, the device store, the host
   and the client ends, pairing. Proven over loopback.
5. `RemoteLibraryService`: every operation Browse and the player use, with a
   contract suite that runs the same assertions against the local service
   and against the remote one through a host on loopback.
6. The relay, and thumbnails from the host.
7. The windows: Remote Access in the host's Settings, the picker's Remote
   list and Connect, and a library window over a remote library. A window not
   yet moved says "Not available for a remote library yet".
8. The remaining windows onto the service, then their remote halves.

## A risk carried forward

A listing is every matching item in one answer. For a very large library that
is tens of megabytes of JSON per change of filter. Compression makes it
smaller, not cheap to encode and decode. Step 5 measures it on a synthetic
library of fifty thousand items before anything is built on it; if it is too
slow the listing gains pages, which changes `ListingRequest` and how the grid
holds its items, and is its own piece of work.
