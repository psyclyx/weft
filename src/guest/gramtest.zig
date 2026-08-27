//! Test fixture ONLY (not installed — see build.zig's `guests` table): the
//! skeleton of the coming Files conformance gate — a synthetic third-party
//! input grammar built using only standard protocols (doc/configuration.md
//! §5.1's `std.*` intentions, src/core/intentions.zig). It declares itself
//! and binds nothing yet; the gate that walks it against the std intention
//! table lands in a later wave. For now the one thing under test is that it
//! loads through the wasm membrane like any other guest.

export fn describe() void {}

export fn init() void {}
