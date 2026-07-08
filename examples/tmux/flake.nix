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
            workDir = null;
            testbedPackages = with pkgs; lib.mkOptionDefault [ tmux ];
            nodePackages = with pkgs; [
              ethtool
              iperf3
              iputils
              netcat
              nmap
              tcpdump
              tshark
              bash
            ];
            nodes = {
              client = {
                networking.interfaces.eth0.ipv4.addresses = [
                  {
                    address = "10.0.0.1";
                    prefixLength = 24;
                  }
                ];
              };
              server = {
                networking.interfaces.eth0.ipv4.addresses = [
                  {
                    address = "10.0.0.2";
                    prefixLength = 24;
                  }
                ];
              };
            };
            scripts.main = {
              foreground = true;
              exec = ''
                SOCKET=/tmp/nixnet.sock
                SESSION=nixnet
                MENU_CMD='display-menu -T " New " -x 0 -y S'
                _new_session=true
                i=0
                for ns in /pwd/*; do
                  if [ ! -d "$ns" ]; then continue; fi
                  ns="$(basename -- "$ns")"
                  if  [ "$_new_session" = true ]; then
                      tmux -S $SOCKET -f ${./tmux.conf} new-session -d -s $SESSION -n "$ns" -- jail enter "$ns" bash
                      _new_session=false
                  else
                      tmux -S $SOCKET new-window -t $SESSION -n "$ns" -- jail enter "$ns" bash
                  fi
                  MENU_CMD="$MENU_CMD \"$ns\" \"$i\" \"new-window -n $ns -- jail enter $ns bash\""
                  i=$((i+1))
                done
                MENU_CMD="$MENU_CMD \"\"" # divider in menu
                MENU_CMD="$MENU_CMD \"Exit Lab\" q \"confirm-before -p \\\"Exit session? (y/n)\\\" detach-client\""
                tmux -S $SOCKET bind-key m "$MENU_CMD"
                tmux -S $SOCKET bind-key -n MouseDown1StatusLeft "$MENU_CMD"
                tmux -S /tmp/nixnet.sock attach-session -t $SESSION
              '';
            };
            veths.eth0 = {
              netem.delayMs = 10;
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
