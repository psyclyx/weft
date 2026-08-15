# scion wire protocol v1 (ABI)

Version-negotiated in the handshake; this document is normative, the
conformance tests in `src/core/wire.zig` are the executable spec.

## Transport

A byte stream (TCP; the session layer is written against a `Link`
vtable so a QUIC implementation can replace it stream-for-stream).
Everything after the handshake is encrypted.

**Security.** Noise-style, built from std.crypto primitives only:
ephemeral X25519 from both sides; keys = HKDF-SHA256(ikm = DH shared
secret, salt = session token, info = transcript hash); per-direction
XChaCha20-Poly1305 with counter nonces; the handshake finishes with
transcript MACs both ways, so a wrong token fails before any payload.
**Trust model**: possession of the shared session token = full peer
rights on the served worktree. No identity, no authorization tiers, no
forward secrecy beyond the ephemeral DH. Fine for "my machines, my
tailnet"; not fine for hostile networks with long-lived tokens.

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
- **3 feed** — latest-wins per (channel, key): the sender-side queue
  coalesces under backpressure by replacing the queued payload for a
  key. Droppable by definition. Presence (cursor per peer) rides here.

**Priority under congestion** (writer drain order): control heartbeats,
then ops, then requests, then feeds (presence keys last), then
prefetch-class requests. One writer, strict class order per drain.

**Liveness**: heartbeats every second each way; peer state machine
connected → degraded (>3s silent) → offline (>10s), surfaced in the
status line. Reconnect with a resume token (issued in hello-ack)
reauths and re-subscribes in one round trip; the op resync happens via
the normal frontier exchange.

## Handshake sequence

    C→S  hello   { version, client_eph_pub, resume_token? }
    S→C  hello2  { version, server_eph_pub, mac_s = MAC(k_s, transcript) }
    C→S  finish  { mac_c = MAC(k_c, transcript) }
    S→C  accept  { session_resume_token }   (encrypted from here on)

MAC failure on either side closes the link before any document data.
