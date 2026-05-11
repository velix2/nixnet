{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      perSystem =
        { pkgs, ... }:
        let
          deps = with pkgs; [
            bash
            coreutils
            util-linux
            iproute2
          ];
          jail = pkgs.writeShellApplication {
            name = "jail";
            runtimeInputs = deps;
            text = builtins.readFile ./jail;
          };
          jail_setup = pkgs.writeShellApplication {
            name = "jail_setup";
            runtimeInputs = deps;
            text = builtins.readFile ./jail_setup;
          };
          jail_init = pkgs.runCommand "jail_init" { nativeBuildInputs = [ pkgs.gcc ]; } ''
            mkdir -p $out/bin
            gcc -O2 -o $out/bin/init ${./init.c}
          '';
        in
        {
          packages.default = pkgs.runCommand "jail" { } ''
            mkdir -p $out/bin
            cp ${jail}/bin/jail $out/bin/jail
            cp ${jail_setup}/bin/jail_setup $out/bin/jail_setup
            cp ${jail_init}/bin/init $out/bin/init
          '';
        };
    };
}
