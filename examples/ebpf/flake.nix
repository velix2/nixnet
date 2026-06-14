{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixnet.url = "github:birneee/nixnet";
    starlink.url = "github:birneee/simple-starlink-ebpf";
  };
  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      perSystem =
        { pkgs, inputs', ... }:
        let
          nixnet = inputs'.nixnet.legacyPackages;
          starlink = inputs'.starlink.packages.default;
          config = {
            nodePackages = with pkgs; [
              iperf3
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
                postSetup = "ip link set dev veth0 xdp obj ${starlink}/starlink.o sec xdp";
                scripts.main = {
                  exec = "sleep 0.1; iperf3 -c 10.0.0.2 -t 30 --forceflush | tee stdout";
                  await = true;
                };
              };
              server = {
                networking.interfaces.veth0.ipv4.addresses = [
                  {
                    address = "10.0.0.2";
                    prefixLength = 24;
                  }
                ];
                postSetup = "ip link set dev veth0 xdp obj ${starlink}/starlink.o sec xdp";
                scripts.main.exec = "iperf3 -s";
              };
            };
            veths.veth0 = {
              netem.delayMs = 40;
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
