{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixnet.url = "github:birneee/nixnet";
    test-certs.url = "github:birneee/test-certs";
    quiche_perf.url = "github:birneee/quiche_perf";
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
              inputs'.quiche_perf.packages.default
              coreutils
            ];
            nodes = {
              client = {
                networking.interfaces.veth0.ipv4.addresses = [
                  {
                    address = "10.0.0.1";
                    prefixLength = 24;
                  }
                ];
                scripts.main = {
                  exec = "QLOGDIR=. RUST_LOG=info quiche-perf client https://10.0.0.2:4433/mem/10MB --cert ${inputs'.test-certs.packages.default}/cert.pem 2> >(tee stderr)";
                  await = true;
                };
                workDir = "./client";
              };
              server = {
                networking.interfaces.veth0.ipv4.addresses = [
                  {
                    address = "10.0.0.2";
                    prefixLength = 24;
                  }
                ];
                scripts.main.exec = "QLOGDIR=. RUST_LOG=info quiche-perf server --cert ${inputs'.test-certs.packages.default}/cert.pem --key ${inputs'.test-certs.packages.default}/key.pem 2> >(tee stderr)";
                workDir = "./server";
              };
            };
            veths.veth0 = {
              arpPrefill = true;
              arp = false;
              mtu = 1500;
              netem = {
                rateMbit = 1000;
                delayMs = 50;
                autoLimit = true;
              };
              a.node = "client";
              b.node = "server";
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
