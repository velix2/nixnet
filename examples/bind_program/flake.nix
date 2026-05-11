{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixnet.url = "github:birneee/nixnet";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      perSystem =
        { inputs', pkgs, ... }:
        let
          nixnet = inputs'.nixnet.legacyPackages;
          config = {
            bind = [
              "/bin/sh"
            ];
            namespaces = {
              host-sh = {
                bind = [
                  "/bind/bin/sh"
                ];
                scripts = [
                  {
                    exec = "/bind/bind/bin/sh --version > ./version.txt 2>&1";
                    await = true;
                  }
                ];
                workDir = "./host-sh";
              };
              nix-sh = {
                scripts = [
                  {
                    exec = "${pkgs.bash}/bin/sh --version > ./version.txt 2>&1";
                    await = true;
                  }
                ];
                workDir = "./nix-sh";
              };
            };
          };
        in
        {
          packages.default = nixnet.mkTestbed config;
          packages.mermaid = nixnet.mkMermaid config;
          packages.mermaid-svg = nixnet.mkMermaidSvg config;
        };
    };
}
