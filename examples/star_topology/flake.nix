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
        {
          pkgs,
          inputs',
          lib,
          ...
        }:
        let
          nixnet = inputs'.nixnet.legacyPackages;
          n = 100;
          mkNode = i: {
            namespaces.${"node${toString i}"} = {
              packages = with pkgs; [ iputils ];
              networking.interfaces.${"eth${toString i}"}.ipv4.addresses = [
                {
                  address = "10.0.0.${toString i}";
                  prefixLength = 24;
                }
              ];
              scripts = [
                {
                  exec =
                    let
                      j = (lib.mod i n) + 1;
                      delay = i / 10.0;
                    in
                    ''
                      sleep ${toString delay}
                      ping -c 1 10.0.0.${toString j}
                    '';
                  await = true;
                }
              ];
            };
            veths = [
              {
                a = {
                  ns = "node${toString i}";
                  iface = "eth${toString i}";
                };
                b = {
                  ns = "br0";
                  iface = "eth${toString i}";
                };
              }
            ];
          };
          nodes = map mkNode (lib.range 1 n);
          config = {
            arp = true;
            workDir = null;
            bridges = [ "br0" ];
            namespaces = lib.mergeAttrsList (map (node: node.namespaces) nodes);
            veths = lib.concatMap (node: node.veths) nodes;
          };
        in
        {
          packages.default = nixnet.mkTestbed config;
          packages.mermaid = nixnet.mkMermaid config;
          packages.mermaid-svg = nixnet.mkMermaidSvg config;
        };
    };
}
