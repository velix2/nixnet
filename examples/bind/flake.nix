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
        { inputs', ... }:
        let
          nixnet = inputs'.nixnet.legacyPackages;
          config = {
            bind = [
              "/etc/hostname"
            ];
            namespaces = {
              guest = {
                bind = [
                  "/bind/etc/hostname"
                ];
                scripts = [
                  {
                    exec = ''
                      cat /bind/bind/etc/hostname | tee ./hostname.txt
                      cat /etc/hostname | tee ./guestname.txt
                    '';
                    await = true;
                  }
                ];
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
