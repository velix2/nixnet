{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixnet.url = "github:birneee/nixnet";
    test-certs.url = "github:birneee/test-certs";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = inputs.nixnet.supportedSystems;
      perSystem =
        { inputs', pkgs, ... }:
        let
          nixnet = inputs'.nixnet.legacyPackages;
          certs = inputs'.test-certs.packages.default;
          quic-go-example = pkgs.buildGoModule {
            name = "quic-go-example";
            src = pkgs.fetchFromGitHub {
              owner = "quic-go";
              repo = "quic-go";
              rev = "v0.60.0";
              hash = "sha256-mQ7TaADEipP1St2p2BBFP/MBSrIyu5QE9WNgMAPGE+A=";
            };
            subPackages = [
              "example"
              "example/client"
            ];
            vendorHash = "sha256-IoGkgMYUw3cceo2sEEMBdh1UBr43tvxnrY34pEewvpc=";
          };
          config = {
            arp = false;
            arpPrefill = true;
            nodes = {
              client = {
                networking.interfaces.eth0.ipv4.addresses = [
                  {
                    address = "10.0.0.1";
                    prefixLength = 24;
                  }
                ];
                packages = [ quic-go-example ];
                workDir = "client";
                scripts.main = {
                  exec = ''
                    mkdir -p github.com/quic-go/quic-go/internal/testdata
                    cp ${certs}/cert.pem github.com/quic-go/quic-go/internal/testdata/ca.pem
                    echo "10.0.0.2 server.test" >> /etc/hosts
                    sleep 0.5
                    client -q https://server.test:6121/demo/tiles
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
                packages = [ quic-go-example ];
                workDir = "server";
                scripts.main.exec = ''
                  example \
                    -bind 10.0.0.2:6121 \
                    -cert ${certs}/cert.pem \
                    -key ${certs}/key.pem
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
