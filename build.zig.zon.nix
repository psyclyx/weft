# The Zig packages build.zig.zon names, as store paths `zig build --system`
# reads by package hash. Keep each entry in step with its zon twin.
{
  linkFarm,
  fetchgit,
  fetchFromGitHub,
  stemma ? (import ./npins).stemma,
}:
linkFarm "weft-zig-packages" [
  {
    name = "stemma-0.7.0-CIOtoNbqCwBhorsLBBKjaG71e9aIaoS639IXd7mrftgx";
    path = stemma;
  }
  {
    # The same fetch as nixpkgs' skia.src (url, rev and hash all equal), so
    # it is that very store path.
    name = "N-V-__8AAEYYSwpL-J-F6MwfVmiUdaOSd3CM1ppnpZObRdX8";
    path = fetchgit {
      url = "https://skia.googlesource.com/skia.git";
      rev = "e7c90ecca9444fe09598f1630ab7cee2c0ee027a";
      hash = "sha256-2+fxWqkNBStoN6l5Y3xMqkwvh69sCU6A//wz8fMnmjY=";
    };
  }
  {
    name = "N-V-__8AAHeWOQABqWHSzsYkiKh9vr8y4hszFdUU0OKecnjX";
    path = fetchFromGitHub {
      owner = "GPUOpen-LibrariesAndSDKs";
      repo = "VulkanMemoryAllocator";
      rev = "a6bfc237255a6bac1513f7c1ebde6d8aed6b5191";
      hash = "sha256-urUebQaPTgCECmm4Espri1HqYGy0ueAqTBu/VSiX/8I=";
    };
  }
]
