{ pkgs }:
let
  lib = pkgs.lib;
  testFiles = lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".nix" n && n != "default.nix") (
    builtins.readDir ./.
  );
  failures = lib.concatLists (
    lib.mapAttrsToList (name: _: import ./${name} { inherit pkgs; }) testFiles
  );
in
pkgs.runCommand "nixnet-tests" { } (
  if failures == [ ] then "touch $out" else throw "Tests failed:\n${builtins.toJSON failures}"
)
