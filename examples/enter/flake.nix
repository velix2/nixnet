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
            workDir = null;
            testbedPackages = pkgs.lib.mkOptionDefault [ pkgs.gnugrep ];
            namespaces = {
              client = {};
            };
            scripts = [
              {
                foreground = true;
                exec = ''
                  jail enter client ps -e | tee /dev/stderr | grep -q '^\s*1\b' || { echo "init process (PID 1) not found"; exit 1; }
                '';
              }
            ];
          };
        in
        {
          packages.default = nixnet.mkTestbed config;
          packages.mermaid = nixnet.mkMermaid config;
          packages.mermaid-svg = nixnet.mkMermaidSvg config;
        };
    };
}
