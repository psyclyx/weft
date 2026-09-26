{
  linkFarm,
  stemma ? (import ./npins).stemma,
}:
linkFarm "weft-zig-packages" [
  {
    name = "stemma-0.7.0-CIOtoNbqCwBhorsLBBKjaG71e9aIaoS639IXd7mrftgx";
    path = stemma;
  }
]
