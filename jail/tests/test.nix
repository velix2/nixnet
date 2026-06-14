{
  pkgs,
  jail ? pkgs.callPackage ../pkgs/jail.nix { },
}:
pkgs.writeShellApplication {
  name = "jail-test";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.bash
    jail
  ];
  text = builtins.readFile ./test;
}
