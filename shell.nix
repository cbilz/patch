{
  pkgs ? import <nixpkgs> { },
  system ? builtins.currentSystem,
}:

let
  zig =
    let
      version = "master-2025-03-04";
    in
    (import (pkgs.fetchFromGitHub {
      owner = "mitchellh";
      repo = "zig-overlay";
      rev = "3592f7125670a97ddf83b1758e5e5e3f6bdb477d";
      sha256 = "sha256-TpOKdoBXnzCqUC60eE/PPSICLSAJp7Ne2RlhYYim5YQ=";
    }) { inherit pkgs system; })."${version}";

  zls =
    let
      # Please find a matching ZLS version on https://zigtools.org/zls/install/
      # whenever the above Zig version is changed.
      version = "0.14.0-dev.406+336f468";
      systems = {
        x86_64-linux = "sha256-mvqJL4iunpK2AHhuLuFptkUsyqrjNcP3A4FTSzWJq6w=";
      };
      sha256 = systems.${system};
      splits = pkgs.lib.strings.splitString "-" system;
      arch = builtins.elemAt splits 0;
      os = builtins.elemAt splits 1;
    in
    pkgs.stdenv.mkDerivation {
      pname = "zls";
      inherit version;
      src = pkgs.fetchurl {
        url = "https://builds.zigtools.org/zls-${os}-${arch}-${version}.tar.xz";
        inherit sha256;
      };
      sourceRoot = ".";
      dontConfigure = true;
      dontBuild = true;
      dontFixup = true;
      installPhase = ''
        mkdir -p $out/bin
        cp zls $out/bin/zls
      '';
    };
in
pkgs.mkShellNoCC {
  packages = [
    zig
    zls
  ];
}
