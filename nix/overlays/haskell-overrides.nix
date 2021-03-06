## Build mellon in non-maintainer mode. This will skip tests that are
## more picky, are not related to functionality, and should not
## interfere with continuous integration builds.

self: super:

let

  lib = (import ../lib);
  inherit (lib) haskell withLocalMellon;
  inherit (haskell.lib) doJailbreak properExtend;

in
{
  ## The default Nixpkgs package set.
  haskellPackages =
    (withLocalMellon (properExtend super.haskellPackages (self: super:
      {
        servant-docs = doJailbreak super.servant-docs;
        insert-ordered-containers = doJailbreak super.insert-ordered-containers;
        tdigest = doJailbreak super.tdigest;
      }
  )));
}
