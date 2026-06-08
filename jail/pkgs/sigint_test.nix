{
  pkgs,
  jail ? pkgs.callPackage ./jail.nix { },
}:
pkgs.writeShellApplication {
  name = "jail-sigint-test";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.bash
    jail
  ];
  text = builtins.readFile ../sigint_test;
}
