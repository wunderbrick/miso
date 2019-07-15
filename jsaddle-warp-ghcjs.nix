{ mkDerivation, base, fetchgit, stdenv }:
mkDerivation {
  pname = "jsaddle-warp";
  version = "0.9.5.0";
  src = fetchgit {
    url = "https://github.com/ghcjs/jsaddle.git";
    sha256 = "1qrjrjagmrrlcalys33636w5cb67db52i183masb7xd93wir8963";
    rev = "1e398448bfa2ae506be6b99912cfa4415f6162c9";
  };
  postUnpack = "sourceRoot+=/jsaddle-warp; echo source root reset to $sourceRoot";
  libraryHaskellDepends = [ base ];
  description = "Interface for JavaScript that works with GHCJS and GHC";
  license = stdenv.lib.licenses.mit;
}
