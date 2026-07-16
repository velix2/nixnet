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
        { inputs', pkgs, ... }:
        let
          nixnet = inputs'.nixnet.legacyPackages;
          inherit (pkgs.lib) mkOptionDefault;
          config = {
            testbedPackages =
              with pkgs;
              mkOptionDefault [
                nftables # todo this options should be at node level
              ];
            nodes = {
              client = {
                networking.interfaces.eth0.ipv4.addresses = [
                  {
                    address = "10.0.0.1";
                    prefixLength = 24;
                  }
                ];
                packages = with pkgs; [
                  iputils
                  netcat-openbsd
                ];
                scripts.main = {
                  exec = ''
                    sleep 0.3
                    ping -c 2 -W 1 10.0.0.2 && exit 1 || echo "ping blocked (expected)"
                    nc -z -w 2 10.0.0.2 8080 || exit 1 && echo "port 8080 allowed (expected)"
                    nc -z -w 2 10.0.0.2 9090 && exit 1 || echo "port 9090 blocked (expected)"
                  '';
                  await = true;
                };
              };

              server = {
                networking.interfaces.eth0.ipv4.addresses = [
                  {
                    address = "10.0.0.2";
                    prefixLength = 24;
                  }
                ];
                packages = with pkgs; [
                  netcat-openbsd
                ];
                postSetup = ''
                  nft -f ${./server.nft}
                '';
                scripts.http.exec = ''
                  while true; do nc -l -p 8080; done
                '';
                scripts.blocked.exec = ''
                  while true; do nc -l -p 9090; done
                '';
              };
            };

            veths.eth0 = {
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
