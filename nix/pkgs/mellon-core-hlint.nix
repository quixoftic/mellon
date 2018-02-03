{ mkDerivation, async, base, doctest, hlint, hspec, mtl, QuickCheck
, quickcheck-instances, stdenv, time, transformers
}:
mkDerivation {
  pname = "mellon-core";
  version = "0.8.0.4";
  src = ../../mellon-core;
  configureFlags = [ "-ftest-hlint" ];
  libraryHaskellDepends = [ async base mtl time transformers ];
  testHaskellDepends = [
    async base doctest hlint hspec mtl QuickCheck quickcheck-instances
    time transformers
  ];
  homepage = "https://github.com/quixoftic/mellon#readme";
  description = "Control physical access devices";
  license = stdenv.lib.licenses.bsd3;
}