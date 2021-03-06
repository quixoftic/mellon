{ mkDerivation, async, base, doctest, hpack, hspec, mtl, protolude
, QuickCheck, quickcheck-instances, stdenv, time, transformers
}:
mkDerivation {
  pname = "mellon-core";
  version = "0.8.0.7";
  src = ../../mellon-core;
  libraryHaskellDepends = [
    async base mtl protolude time transformers
  ];
  libraryToolDepends = [ hpack ];
  testHaskellDepends = [
    async base doctest hspec mtl protolude QuickCheck
    quickcheck-instances time transformers
  ];
  prePatch = "hpack";
  homepage = "https://github.com/dhess/mellon#readme";
  description = "Control physical access devices";
  license = stdenv.lib.licenses.bsd3;
}
