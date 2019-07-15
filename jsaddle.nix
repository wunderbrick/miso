with (builtins.fromJSON (builtins.readFile ./nixpkgs.json));
with (import (builtins.fetchTarball {
       url = "https://github.com/NixOS/nixpkgs/archive/${rev}.tar.gz";
       inherit sha256;
     }) {});
with haskell.lib;
let
  haskellPkgs = pkgs.haskell.packages.ghc865.override (oldAttrs: {
    overrides = self: super: {
      miso = pkgs.lib.overrideDerivation (super.callPackage ./miso-ghc-jsaddle.nix {}) (drv: {
        configureFlags = [ "-fexamples" "-fjsaddle" ];
      });
     };
    });
in
{ miso = haskellPkgs.miso;
  miso-shell = haskellPkgs.shellFor { packages = p: [p.miso]; withHoogle = true; };
}
