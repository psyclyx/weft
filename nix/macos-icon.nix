# weft.icns: the dashboard's mark (assets/brand/weft-app-icon-macos.svg, the
# app icon on Apple's grid) rasterized at every size an .icns carries. Built
# from the SVG rather than checked in, so the bundle's icon cannot drift from
# the mark. Both tools run on the build host, so a Linux → macOS cross build
# makes it too.
{
  runCommand,
  librsvg,
  libicns,
}:
runCommand "weft.icns"
  {
    nativeBuildInputs = [
      librsvg
      libicns
    ];
  }
  ''
    for size in 16 32 48 128 256 512 1024; do
      rsvg-convert -w $size -h $size ${../assets/brand/weft-app-icon-macos.svg} -o icon_$size.png
    done
    png2icns $out icon_*.png
  ''
