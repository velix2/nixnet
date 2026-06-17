{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixnet.url = "github:birneee/nixnet";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = inputs.nixnet.supportedSystems;
      perSystem =
        { pkgs, inputs', ... }:
        let
          nixnet = inputs'.nixnet.legacyPackages;
          config = {
            arp = false;
            arpPrefill = true;
            nodePackages = with pkgs; [
              iperf3
              coreutils
            ];
            nodes = {
              ns-client = {
                networking.interfaces.veth0.ipv4 = {
                  addresses = [
                    {
                      address = "10.0.0.1";
                      prefixLength = 24;
                    }
                  ];
                  routes = [
                    {
                      address = "10.0.1.0";
                      prefixLength = 24;
                      via = "10.0.0.2";
                    }
                  ];
                };
                scripts.main = {
                  exec = ''
                    sleep 0.1
                    iperf3 -c 10.0.1.2 > ./stdout 2>&1
                  '';
                  await = true;
                };
                workDir = "./client";
              };
              ns-router = {
                networking.interfaces = {
                  veth0.ipv4.addresses = [
                    {
                      address = "10.0.0.2";
                      prefixLength = 24;
                    }
                  ];
                  veth1.ipv4.addresses = [
                    {
                      address = "10.0.1.1";
                      prefixLength = 24;
                    }
                  ];
                };
                sysctl."net.ipv4.ip_forward" = true;
              };
              ns-server = {
                networking.interfaces.veth0.ipv4 = {
                  addresses = [
                    {
                      address = "10.0.1.2";
                      prefixLength = 24;
                    }
                  ];
                  routes = [
                    {
                      address = "10.0.0.0";
                      prefixLength = 24;
                      via = "10.0.1.1";
                    }
                  ];
                };
                scripts.main.exec = "iperf3 -s > ./stdout 2>&1";
                workDir = "./server";
              };
            };
            veths.veth0 = {
              netem.delayMs = 50;
              a.node = "ns-client";
              b.node = "ns-router";
            };
            veths.veth1 = {
              a.node = "ns-router";
              b = {
                node = "ns-server";
                iface = "veth0";
              };
            };
          };
        in
        {
          packages.default = nixnet.mkExperiment config;
          packages.mermaid = nixnet.mkMermaid config;
          packages.mermaid-svg = nixnet.mkMermaidSvg config;
        };
    };
}
