{
  pkgs,
  jail ? pkgs.callPackage ../pkgs/jail.nix { },
}:
pkgs.writeShellApplication {
  name = "jail-sigint-test";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.bash
    jail
  ];
  text = builtins.readFile ./sigint_test;
}
