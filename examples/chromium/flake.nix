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
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      perSystem =
        { pkgs, inputs', ... }:
        let
          nixnet = inputs'.nixnet.legacyPackages;
          certs = inputs'.test-certs.packages.default;
          fontsConf = pkgs.makeFontsConf { fontDirectories = with pkgs; [ noto-fonts ]; };
          config = {
            workDir = null;
            shareWayland = true;
            arp = false;
            arpPrefill = true;
            namespaces = {
              client = {
                shareWayland = true;
                packages = with pkgs; [ chromium ];
                networking.interfaces.veth0.ipv4 = {
                  addresses = [
                    {
                      address = "10.0.0.1";
                      prefixLength = 24;
                    }
                  ];
                };
                scripts = [
                  {
                    exec = ''
                      FONTCONFIG_FILE=${fontsConf} chromium \
                        --origin-to-force-quic-on="*" \
                        --ignore-certificate-errors-spki-list=$(cat ${certs}/spki) \
                        --test-type \
                        --no-sandbox \
                        https://10.0.0.2/
                    '';
                    await = true;
                  }
                ];
              };
              server = {
                packages = with pkgs; [ nginx ];
                networking.interfaces.veth0.ipv4 = {
                  addresses = [
                    {
                      address = "10.0.0.2";
                      prefixLength = 24;
                    }
                  ];
                };
                scripts = [
                  {
                    exec = ''
                      mkdir -p /tmp/nginx/www /tmp/nginx/logs
                      echo 'hello from nixnet' > /tmp/nginx/www/index.html
                      cat > /tmp/nginx/nginx.conf << 'EOF'
                      user root;
                      daemon off;
                      pid /tmp/nginx/nginx.pid;
                      events {}
                      http {
                        access_log /tmp/nginx/logs/access.log;
                        server {
                          listen 443 ssl;
                          listen 443 quic reuseport;
                          ssl_certificate ${certs}/cert.pem;
                          ssl_certificate_key ${certs}/key.pem;
                          add_header Alt-Svc 'h3=":443"; ma=86400';
                          root /tmp/nginx/www;
                        }
                      }
                      EOF
                      nginx -e /tmp/nginx/error.log -p /tmp/nginx -c /tmp/nginx/nginx.conf
                    '';
                  }
                ];
              };
            };
            veths = [
              {
                a = {
                  ns = "client";
                  iface = "veth0";
                };
                b = {
                  ns = "server";
                  iface = "veth0";
                };
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
