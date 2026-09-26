#!/usr/bin/env bash
# Turn a verified Nix build into a self-contained /opt/weft payload for
# distribution packages. The runtime ELF loader and shared libraries live
# inside /opt/weft; plugins, desktop metadata, and the icon keep their normal
# installed layout. Run on x86_64 Linux with patchelf and ldd.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 NIX_OUTPUT DESTINATION" >&2
  exit 2
fi
source_root=$(realpath "$1")
destination=$2
if [[ $(uname -m) != x86_64 ]]; then
  echo "portable bundle currently supports x86_64 only" >&2
  exit 2
fi
if [[ ! -x "$source_root/bin/weft" ]]; then
  echo "expected Weft at $source_root/bin/weft" >&2
  exit 2
fi
if [[ -e $destination && -n $(find "$destination" -mindepth 1 -print -quit) ]]; then
  echo "destination must be empty: $destination" >&2
  exit 2
fi

mkdir -p "$destination/opt/weft/bin" "$destination/opt/weft/lib" "$destination/usr/bin" \
  "$destination/usr/share/applications" "$destination/usr/share/icons/hicolor/scalable/apps" \
  "$destination/usr/share/licenses/weft"
cp -L "$source_root/bin/weft" "$destination/opt/weft/bin/weft"
cp -a "$source_root/lib/weft" "$destination/opt/weft/lib/"
chmod -R u+w "$destination/opt/weft/lib/weft"
cp -a "$source_root/share/applications/weft.desktop" "$destination/usr/share/applications/"
cp -a "$source_root/share/icons/hicolor/scalable/apps/weft.svg" "$destination/usr/share/icons/hicolor/scalable/apps/"
cp -a "$source_root/share/licenses/weft/LICENSE" "$destination/usr/share/licenses/weft/"

loader=$(patchelf --print-interpreter "$source_root/bin/weft")
cp -L "$loader" "$destination/opt/weft/lib/ld-linux-x86-64.so.2"
dependencies=$(ldd "$source_root/bin/weft")
if [[ $dependencies == *'not found'* ]]; then
  echo "the Nix build has an unresolved shared library" >&2
  exit 1
fi
while IFS= read -r library; do
  [[ -n $library ]] || continue
  base=$(basename "$library")
  [[ $base == ld-linux-x86-64.so.2 ]] && continue
  target="$destination/opt/weft/lib/$base"
  if [[ -e $target ]] && ! cmp -s "$library" "$target"; then
    echo "conflicting library basename: $library" >&2
    exit 1
  fi
  cp -L "$library" "$target"
done < <(printf '%s\n' "$dependencies" | awk '/=> \/nix\/store\// { print $3 } /^[[:space:]]*\/nix\/store\// { print $1 }' | sort -u)

chmod u+w "$destination/opt/weft/bin/weft" "$destination"/opt/weft/lib/*.so*
patchelf --set-interpreter /opt/weft/lib/ld-linux-x86-64.so.2 \
  --set-rpath '$ORIGIN/../lib' "$destination/opt/weft/bin/weft"
for library in "$destination"/opt/weft/lib/*.so*; do
  [[ -f $library ]] || continue
  if [[ $(basename "$library") == ld-linux-x86-64.so.2 ]]; then continue; fi
  patchelf --set-rpath '$ORIGIN' "$library"
done
cat > "$destination/usr/bin/weft" <<'EOF'
#!/bin/sh
exec /opt/weft/bin/weft "$@"
EOF
chmod 755 "$destination/usr/bin/weft" "$destination/opt/weft/bin/weft"
