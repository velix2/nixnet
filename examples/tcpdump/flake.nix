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
        { pkgs, inputs', ... }:
        let
          nixnet = inputs'.nixnet.legacyPackages;
          config = {
            arp = false;
            arpPrefill = true;
            nodePackages = with pkgs; [
              iperf3
              tcpdump
              coreutils
            ];
            nodes = {
              client = {
                workDir = "client";
                networking.interfaces.veth0.ipv4.addresses = [
                  {
                    address = "10.0.0.1";
                    prefixLength = 24;
                  }
                ];
                scripts.main = {
                  exec = ''
                    tcpdump -i veth0 -w iperf.cap &
                    TD_PID=$!
                    cleanup() {
                      kill $TD_PID
                      wait $TD_PID
                    }
                    trap cleanup EXIT
                    sleep 0.1
                    iperf3 -c 10.0.0.2 -t 1 > stdout
                  '';
                  await = true;
                };
              };
              server = {
                workDir = "server";
                networking.interfaces.veth0.ipv4.addresses = [
                  {
                    address = "10.0.0.2";
                    prefixLength = 24;
                  }
                ];
                scripts.main.exec = ''
                  tcpdump -i veth0 -w iperf.cap &
                  TD_PID=$!
                  cleanup() {
                    kill $TD_PID
                    wait $TD_PID
                  }
                  trap cleanup EXIT
                  iperf -s > stdout
                '';
              };
            };
            veths.veth0 = {
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
