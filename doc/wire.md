# weft wire protocol v2 (ABI)

Version-checked in the handshake; this document is normative, the
conformance tests in `src/core/wire.zig` are the executable spec.

## Transport

A byte stream (TCP; the session layer is written against a `Link`
vtable so a QUIC implementation can replace it stream-for-stream).
Everything after the handshake is encrypted.

**Security.** Noise-style, built from std.crypto primitives only. Each
side contributes an ephemeral X25519 key *and* its long-term identity
X25519 key. Two Diffie-Hellmans feed the schedule: the ephemeral one
(forward secrecy) and the static identity one, `ss` (authentication).
keys = HKDF-SHA256(ikm = ee ‖ ss, salt = session token, info =
transcript hash), where the transcript is both ephemerals ‖ both
identity keys; per-direction XChaCha20-Poly1305 with counter nonces; the
handshake finishes with transcript MACs both ways, so a wrong token — or
a party that does not hold the identity secret behind the key it
presented — fails before any payload.

**Trust model.** Three layers, kept distinct:

- *Authentication* — possession of the session token gates connection;
  mixing `ss` additionally proves each side holds its claimed identity
  key, so a returning peer is cryptographically the same weft.
- *Identity & TOFU* — a peer is named by its identity key's fingerprint
  (five base32 groups). First contact with an unknown fingerprint is
  accepted but recorded UNVERIFIED (`known_peers`, the SSH known_hosts
  model). Because there is no CA, a man in the middle is caught by a
  **Short Authentication String**: four spoken words derived from the
  transcript (identity keys included). A MITM runs a separate exchange
  with each side, so the two ends compute different words; reading them
  aloud over any authentic channel exposes it. Confirming the SAS once
  marks the fingerprint verified and future sessions auto-trust.
- *Authorization* — an independent per-peer grade (view/edit/own),
  enforced by the host at op admission; the token/crypto say you *may
  connect*, the grade says what you *may do*.

Forward secrecy is the ephemeral DH's. Fine for "my machines, my
tailnet"; the SAS extends it to "someone I can call and read four words
to" without a CA.

## Frames

    u32le body_len | u8 class | u8 kind | uvarint channel | payload

Every frame belongs to exactly one class — ambiguity is a spec bug:

- **0 control** — hello / hello-ack / heartbeat / resume. Never
  coalesced, never dropped.
- **1 op** — CRDT event batches: payload = stemma wire bytes (the
  event graph encoding is stemma's, not duplicated here; run-RLE is
  proposed upstream, see doc/stemma-rle-proposal.md). Causal delivery
  by stream order; idempotent by event id, so blind retransmit on
  reconnect is safe. Resync = frontier-token exchange → exactly the
  missing subgraph (`eventsSince`). Offline/reconnect is only this.
- **2 request** — client-generated u64 ids (dedup across reconnects),
  explicit timeout/cancel/failure kinds. Save/fetch/spawn live here.
  Every call is issued under a **requester-side deadline** (10 s by
  default, settable per request): when it passes, the caller gets an
  explicit failure — never an unbounded wait for a reply that is not
  coming. A responder that cannot serve a call says so, with `err`
  (blob/base) or `fs_err` (`.peer` filesystem), payload `uv id` alone;
  the two cycles number their ids independently, which is why the
  failure kind is split exactly like `ok`/`fs_ok`. A peer that predates
  a failure kind ignores it and falls back to the deadline. Retrying is
  the caller's policy, never the transport's.
- **3 feed** — latest-wins per (channel, key): the sender-side queue
  coalesces under backpressure by replacing the queued payload for a
  key. Droppable by definition. Presence (cursor per peer) rides here.

**Priority under congestion** (writer drain order): control heartbeats,
then ops, then requests, then feeds (presence keys last), then
prefetch-class requests. One writer, strict class order per drain.

**Liveness**: heartbeats every second each way; peer state machine
connected → degraded (>3s silent) → offline (>10s), surfaced in the
status line. Reconnect is a fresh handshake: share announcements
replay (idempotent) and the op resync is the normal frontier
exchange — nothing else needs resuming.

## Handshake sequence

    C→S  hello   { u16le wire_version, client_eph_pub, client_id_pub }
    S→C  hello2  { u16le wire_version, server_eph_pub, server_id_pub, mac_s = MAC(k_s, transcript) }
    C→S  finish  { mac_c = MAC(k_c, transcript) }   (encrypted from here on)

MAC failure on either side closes the link before any document data.
An unequal wire version closes it before key derivation; there is one codec,
not a compatibility branch that can silently reinterpret a feed.
Identity keys are sent in the clear (public keys are public); this
leaks *who* is connecting to a passive observer but not the session
contents — acceptable for the current threat model, and the point where
a Noise_XX-style encrypted-identity flow would slot in if that changes.
The four-word SAS is derived from the same transcript and shown on both
ends for out-of-band comparison.

**Resume tokens: rejected.** An earlier draft promised a resume-token
fast path. It is deliberately not implemented: the fresh handshake is
~1.5 RTT with one X25519 (dwarfed by TCP setup and the 3 s reconnect
cadence), resync is the frontier exchange, and re-subscription is the
idempotent share re-announce — a second authentication path would add
attack surface and connection states for no measurable latency win.
Revisit only if a 0-RTT transport (below) changes the arithmetic.

## Transport (QUIC: deferred, deliberately)

The session layer is written against the `Link` vtable precisely so a
stream transport can be swapped in. QUIC is NOT hand-rolled here: a
from-scratch QUIC+TLS stack is a security liability that would dwarf
this codebase, and the wire already provides its own encryption,
multiplexing (channel quads), and loss-tolerant semantics (idempotent
ops, latest-wins feeds) over any reliable stream. When a pinnable Zig
QUIC implementation is worth adopting, it slots in behind `Link`
stream-for-stream; until then TCP (or anything ssh/tailscale can
carry) is the transport.

## Shared buffers (v1.1, additive)

Channels are allocated in **quads**: `base` carries op batches,
`base+1` the presence feed, `base+2` the diagnostics feed, `base+3`
blob requests. The pre-sharing protocol is exactly quad 0 (ops 0,
presence 1, diagnostics 2, blob 3), bound by convention on both ends —
nothing changed on the wire for the primary document.

Presence on `base+1` is latest-wins soft state keyed by peer name, but its
positions are never projected byte offsets:

    uv name_len | name | u8 present
    if present:
      anchor head | anchor selection | uv hue16

An anchor is `uv agent_len | agent | uv event_seq | u8 side`, the portable
Stemma event identity. Empty `agent` denotes a document boundary. A receiver
retains an anchor whose introducing op has not arrived yet and resolves it
after the op merge; a compacted or malformed identity is omitted rather than
guessed. `present=0` removes a previously published cursor, including when the
sender cannot name an interior compacted position safely.

A buffer is shared with an op-class `share` frame (kind 2) on channel
0: payload = `uv base | uv name_len | name`. Base allocation is
role-split so both sides can share concurrently without coordination:
servers allocate 16, 24, 32, …; clients 20, 28, 36, …. The receiver
records the offer; opening it is local (bind a Collab at that base and
announce a frontier — the ordinary exchange bootstraps content, since
an empty frontier elicits the full history). Frames on unbound quads
drop harmlessly; re-announcing a known base is a no-op (reconnects
re-announce all shares). There is no unshare frame yet: closing a
shared buffer simply stops answering its quad.

## Access grants (v1.2, additive)

Authorization is host-decided: a peer's grade (`view` < `edit` < `own`)
governs whether its ops are admitted to the shared document. The host
announces that grade to the peer with an op-class **`grant` frame (kind
3)** on a quad's `base`: payload = one byte, the `Access` value. It is
sent once the grade is known and re-sent whenever it changes
(`setPeerAccess`), so the client learns what it may do and refuses local
edits its ops would only be dropped for — no divergent ghost. The frame
flows host→client only: a client ignores an inbound `grant` (it is the
one being graded, never the grader), which keeps a peer from gagging the
host's own user. A peer built before v1.2 ignores kind 3 (unknown op
kinds are skipped), so the addition is backward-tolerant; the wire
version is unchanged.

## Publications (v1.3, additive)

A quad is transport. What it MEANS is its **publication descriptor**
(architecture §13.2): the replica it carries plus the endpoint surfaces
its owner exports. Two op-class kinds on channel 0 carry it, and they
replace nothing — `share` still announces the quad.

- **`publish` (kind 5)**: `uv base | uv id | uv epoch | u8 lifetime |
  uv resource_len | resource | uv export_count | (uv len | body)*`.
  Each export is length-framed so an unknown tag or surface is skipped
  export-by-export rather than desynchronizing the payload. A body is
  `u8 tag=0 | u8 replica_kind | u8 admission` or `u8 tag=1 | u8 surface |
  u8 ops`. v1 surfaces are `presence | diagnostics | fs_hierarchy |
  fs_bytes | fs_mutate` — exactly the traffic the quad already carries.
- **`unpublish` (kind 6)**: `uv base | uv epoch`. Exports are revoked,
  the epoch advances, the receiver marks the quad stale and invalidates
  everything it translated out of it (rendered peer cursors, imported
  host diagnostics). The replica survives as an ordinary local document.

Owner and audience are NOT on the wire: they are the authenticated
participants of the connection a descriptor arrives on. A self-asserted
owner would be a spoof, not an authority.

Routing is unchanged — by quad, `base = channel & ~3`. The descriptor
only decides which surfaces are LIVE: an inbound frame for a surface the
quad does not export is dropped with one line in the log, never a crash
and never a silent acceptance. Replies (`ok`/`err`/`fs_ok`/`fs_err`) are
never gated — an answer to a call we made is not an invocation, and
settling it beats waiting out a deadline.

**Degradation.** A quad with no descriptor is the legacy bundle — replica
+ presence + diagnostics + blobs — and is ungated. That is exactly what a
peer built before v1.3 presents: it never emits kinds 5/6 and skips them
inbound, so both ends behave precisely as they did before. A narrowed
export set is therefore only observed by peers that understand it; the
owner still enforces authority at admission either way.
