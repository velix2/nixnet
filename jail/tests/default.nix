{ pkgs, jail }:
let
  lib = pkgs.lib;
  testFiles = lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".nix" n && n != "default.nix") (
    builtins.readDir ./.
  );
in
lib.mapAttrs' (
  name: _:
  let
    pkg = pkgs.callPackage ./${name} { inherit jail; };
  in
  lib.nameValuePair (lib.removeSuffix ".nix" name) (
    pkgs.runCommand pkg.name
      {
        __noChroot = true;
        nativeBuildInputs = [ pkg ];
      }
      ''
        ${pkg.name}
        touch $out
      ''
  )
) testFiles
