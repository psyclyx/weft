#!/usr/bin/env bash
# Build a Debian package from a bundle produced by make-bundle.sh.
set -euo pipefail
if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: $0 BUNDLE_DIRECTORY OUTPUT.deb [VERSION]" >&2
  exit 2
fi
bundle=$1
output=$2
version=${3:-0.0.0-1}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -a "$bundle/." "$work/"
chmod -R u+w "$work"
mkdir -p "$work/DEBIAN"
cat > "$work/DEBIAN/control" <<EOF
Package: weft
Version: $version
Section: editors
Priority: optional
Architecture: amd64
Maintainer: Weft contributors
Depends: libvulkan1
Description: Weft text editor
 A graphical editor with sandboxed plugins.
EOF
dpkg-deb --root-owner-group --build "$work" "$output"
