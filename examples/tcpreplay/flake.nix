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
          pcap = pkgs.fetchurl {
            url = "https://wiki.wireshark.org/uploads/__moin_import__/attachments/SampleCaptures/sip-rtp-opus.pcap";
            hash = "sha256-yJICOO3MlhiAR4EqBenSzoSkCUUpo0NP6h6j2StxP94=";
          };
          config = {
            nodes = {
              sender = {
                networking.interfaces.eth0.ipv4.addresses = [
                  {
                    address = "10.0.0.1";
                    prefixLength = 24;
                  }
                ];
                packages = with pkgs; [ tcpreplay ];
                scripts.main = {
                  exec = ''
                    sleep 1
                    tcpreplay --intf1=eth0 ${pcap}
                  '';
                };
              };
              receiver = {
                networking.interfaces.eth0.ipv4.addresses = [
                  {
                    address = "10.0.0.2";
                    prefixLength = 24;
                  }
                ];
                packages = with pkgs; [ wireshark-cli ];
                scripts.main = {
                  exec = ''
                    tshark -i eth0 -q \
                      -a duration:5 \
                      -z io,phs
                  '';
                  await = true;
                };
              };
            };
            veths.eth0 = {
              a.node = "sender";
              b.node = "receiver";
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
