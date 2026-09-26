# Linux packages

Build the pinned Nix package, then assemble a portable bundle for Arch and
Debian. The bundle carries the editor's native shared libraries, Wasm plugins,
desktop entry, icon, and license. A config or language plugin registers
Tree-sitter grammars and query paths; no grammar is part of the editor package.

```sh
out=$(nix-build default.nix -A packages.weft --no-out-link)
packaging/make-bundle.sh "$out" /tmp/weft-bundle
```

On Arch, create the `source` archive and run `makepkg`:

```sh
tar -C /tmp -czf "$PWD/packaging/arch/weft-bundle.tar.gz" weft-bundle
cd packaging/arch && makepkg -s
```

On Debian, run:

```sh
packaging/debian/build-deb.sh /tmp/weft-bundle weft_0.0.0-1_amd64.deb
```

The portable payload currently targets x86_64 Linux. The package installs
`/usr/bin/weft`, `/opt/weft`, and desktop metadata under `/usr/share`.
