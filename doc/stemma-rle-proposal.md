# Proposal: run-RLE event encoding in stemma (upstream)

weft's wire ships v1 on stemma's existing per-unit-event encoding
("stg\x01/\x02"): a typing burst of N characters costs N events on the
wire (~6-10 bytes each after LEB128). stemma's own BENCHMARKS ledger
already lists "run-RLE events" as the first optimization-ladder step.

Per the phase-2 rule (one encoding, owned by stemma — weft must not
invent a second), the ask upstream is: a v3 batch section encoding
runs — (agent, first_seq, parent-of-first, count, base_pos,
direction, packed chars) for monotone insert runs and (agent,
first_seq, count, pos) for delete runs — decoded back to unit events
on merge, so the graph model is unchanged and old decoders can be
served v2 on request. Expected effect: typing bursts become one run
frame; the 7-day-offline resync payload shrinks by roughly the
character count of contiguous typing.

Not implemented in weft; wire v1 negotiates versions precisely so the
batch payload can upgrade when stemma lands this.
