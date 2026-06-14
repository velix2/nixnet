{ pkgs, config }:
let
  lib = pkgs.lib;
  writeRunJson =
    (pkgs.writeShellApplication {
      name = "write_run_json";
      runtimeInputs = with pkgs; [
        coreutils
        gnugrep
        gawk
        findutils
        inetutils
      ];
      text = builtins.readFile ./write_run_json;
    }).outPath
    + "/bin/write_run_json";
  nodes = config.nodes;
  veths = lib.attrValues config.veths;
  workDir = config.workDir;
  workDirEnsureEmpty = config.workDirEnsureEmpty;

  # Find the veth that connects to a given node interface, or null if absent.
  getVeth =
    nodeName: ifaceName:
    lib.findFirst (
      v:
      (v.a.node == nodeName && v.a.iface == ifaceName) || (v.b.node == nodeName && v.b.iface == ifaceName)
    ) null veths;

  # Look up the interface config for a veth endpoint from its node, or null if absent.
  getNodeIface =
    endpoint:
    if nodes ? ${endpoint.node} && nodes.${endpoint.node}.networking.interfaces ? ${endpoint.iface} then
      nodes.${endpoint.node}.networking.interfaces.${endpoint.iface}
    else
      null;

  inherit (import ./common.nix { inherit pkgs; })
    concatNonEmpty
    mkPathLines
    resolveFirst
    resolveNetem
    ;

  # Emit a commented bash section only when lines is non-empty.
  mkBashSection =
    title: lines:
    let
      content = concatNonEmpty lines;
    in
    lib.optionalString (content != "") "# ${title}\n${content}";

  # Generate two shell commands for both endpoints of a veth.
  mkVethPairCmds =
    f:
    map (
      veth:
      concatNonEmpty [
        (f veth.a)
        (f veth.b)
      ]
    ) veths;

  # True if (node, ifaceName) is an endpoint of any veth.
  isVethEndpoint =
    node: ifaceName:
    builtins.any (
      veth:
      (veth.a.node == node && veth.a.iface == ifaceName)
      || (veth.b.node == node && veth.b.iface == ifaceName)
    ) veths;

  nodeScripts = import ./node_script.nix { inherit pkgs config; };

  # Extract host paths embedded via nixnet.hostBind from a string's Nix context.
  # Returns list of AttrSet { path: string; readonly: bool;}
  extractHostBinds =
    str:
    lib.concatMap (
      storePath:
      if (lib.hasSuffix "-nixnet-hostbind" (baseNameOf storePath)) then
        [
          {
            path = lib.trim (builtins.readFile storePath);
            readonly = false;
          }
        ]
      else if (lib.hasSuffix "-nixnet-ro-hostbind" (baseNameOf storePath)) then
        [
          {
            path = lib.trim (builtins.readFile storePath);
            readonly = true;
          }
        ]
      else
        [ ]
    ) (lib.attrNames (builtins.getContext str));

  # Extract host bind paths from a nixnet.linkFarm package.
  # Returns list of AttrSet { path: string; readonly: bool;}
  extractHostBindsFromPkg =
    pkg:
    if pkg._nixnetLinkFarm or false then lib.concatMap extractHostBinds (pkg._binds or [ ]) else [ ];

  # Auto-collected host bind paths per node (from script exec strings + per-node packages + shared packages).
  nodeAutoHostBinds = lib.mapAttrs (
    _nodeName: nodeCfg:
    lib.unique (
      lib.concatMap (scriptCfg: extractHostBinds scriptCfg.exec) (lib.attrValues nodeCfg.scripts)
      ++ lib.concatMap extractHostBindsFromPkg (nodeCfg.packages ++ config.nodePackages)
    )
  ) nodes;

  # Union of all node auto host bind paths.
  tbAutoHostBinds = lib.unique (lib.concatLists (lib.attrValues nodeAutoHostBinds));

  # Create nodes (including bridge nodes)
  nodeCreateCommands =
    map (
      name:
      let
        nodeCfg = nodes.${name} or null;
        dir = lib.optionalString (nodeCfg != null && nodeCfg.workDir != null) (
          builtins.replaceStrings [ "{node}" ] [ name ] nodeCfg.workDir
        );
        nodePkgs = (nodeCfg.packages or [ ]) ++ config.nodePackages;
        nodePathLines = mkPathLines nodePkgs;
        wayland = lib.optionalString (
          nodeCfg != null && (nodeCfg.shareWayland or false)
        ) " \\\n  --wayland";
        pipewire = lib.optionalString (nodeCfg != null && (nodeCfg.sharePipeWire or false)) (
          " \\\n  --ro-bind \"$XDG_RUNTIME_DIR/\${PIPEWIRE_REMOTE:-pipewire-0}\" \"/run/user/0/pipewire-0\""
          + " \\\n  --ro-bind \"$XDG_RUNTIME_DIR/pulse/native\" \"/run/user/0/pulse/native\""
          + " \\\n  --setenv \"XDG_RUNTIME_DIR=/run/user/0\""
          + " \\\n  --setenv \"PIPEWIRE_REMOTE=pipewire-0\""
          + " \\\n  --setenv \"PULSE_SERVER=unix:/run/user/0/pulse/native\""
        );
        binds = lib.concatMapStrings (
          binding:
          if binding.readonly then
            " \\\n  --ro-bind '/ro-host${binding.path}' '/ro-host${binding.path}'"
          else
            " \\\n  --bind '/host${binding.path}' '/host${binding.path}'"
        ) (nodeAutoHostBinds.${name} or [ ]);
      in
      lib.concatStringsSep "\n" (
        [ "_PATH=\"\" # clear path" ]
        ++ [ nodePathLines ]
        ++ lib.optional (dir != "") "mkdir -p '${dir}'"
        ++ [
          "jail add \\\n  --setenv PATH=$_PATH${
            lib.optionalString (dir != "") " \\\n  --bind '${dir}' /pwd \\\n  --chdir /pwd"
          }${wayland}${pipewire}${binds} \\\n  ${name}"
        ]
      )
    ) (lib.attrNames nodes)
    ++ map (name: "jail add ${name}") config.bridges;

  # Bring loopback interfaces up
  nodeLoUpCommands = lib.mapAttrsToList (name: _: "ip netns exec ${name} ip link set lo up") nodes;

  nodePreSetupCommands = lib.mapAttrsToList (
    nodeName: nodeCfg:
    lib.optionalString (nodeCfg.preSetup != "") ''
      ip netns exec ${nodeName} bash -c ${lib.escapeShellArg nodeCfg.preSetup}
    ''
  ) nodes;

  nodePostSetupCommands = lib.mapAttrsToList (
    nodeName: nodeCfg:
    lib.optionalString (nodeCfg.postSetup != "") ''
      ip netns exec ${nodeName} bash -c ${lib.escapeShellArg nodeCfg.postSetup}
    ''
  ) nodes;

  # Testbed-level sysctl defaults (lowest priority, can be overridden via config.sysctl or nodeCfg.sysctl)
  tbSysctlDefaults = {
    "net.ipv4.ping_group_range" = "0 0";
    "net.ipv4.ip_unprivileged_port_start" = 0;
  };

  # Apply sysctl per node: tbSysctlDefaults < config.sysctl < nodeCfg.sysctl
  nodeSysctlCommands = lib.concatLists (
    lib.mapAttrsToList (
      nodeName: nodeCfg:
      let
        merged = tbSysctlDefaults // config.sysctl // nodeCfg.sysctl;
      in
      lib.mapAttrsToList (
        key: value:
        lib.optionalString (value != null) (
          let
            rendered =
              if builtins.isBool value then
                (if value then "1" else "0")
              else if builtins.isString value then
                "\"${value}\""
              else
                toString value;
          in
          "ip netns exec ${nodeName} sysctl -w ${key}=${rendered} > /dev/null"
        )
      ) merged
    ) nodes
  );

  # Build a tc netem command string from a resolved netem config and interface.
  mkNetemCmd =
    ns: netemCfg: mtu: dev:
    lib.optionalString (netemCfg != null) (
      let
        n = netemCfg;
        # BDP in bytes: rateMbit * 1_000_000 / 8 * delayMs / 1000
        # BDP in packets: BDP_bytes / mtu
        bdpPackets =
          if n.delayMs != null && n.rateMbit != null && mtu != null then
            n.rateMbit * 1000000 / 8 * n.delayMs / 1000 / mtu
          else
            null;
        effectiveLimit =
          if n.limit != null then
            n.limit
          else if n.autoLimit == true then
            if bdpPackets != null then
              bdpPackets
            else
              throw "netem autoLimit requires delayMs, rateMbit, and mtu to all be set on interface '${dev}'"
          else
            null;
        params = lib.concatStringsSep " " (
          lib.filter (s: s != "") [
            (lib.optionalString (n.delayMs != null) "delay ${toString n.delayMs}ms")
            (lib.optionalString (n.lossPercent != null) "loss ${toString n.lossPercent}%")
            (lib.optionalString (n.rateMbit != null) "rate ${toString n.rateMbit}Mbit")
            (lib.optionalString (effectiveLimit != null) "limit ${toString effectiveLimit}")
          ]
        );
      in
      "ip netns exec ${ns} tc qdisc add dev ${dev} root netem ${params}"
    );

  # Create veth pairs
  vethCreateCommands = map (
    veth:
    "ip netns exec ${veth.a.node} ip link add ${veth.a.iface} type veth peer name ${veth.b.iface} netns ${veth.b.node}"
  ) veths;

  # All {nodeName, ifaceName} pairs from networking.interfaces that are not a veth endpoint.
  dummyIfaces = lib.concatLists (
    lib.mapAttrsToList (
      nodeName: nodeCfg:
      lib.concatMap (
        ifaceName: lib.optional (!isVethEndpoint nodeName ifaceName) { inherit nodeName ifaceName; }
      ) (lib.attrNames nodeCfg.networking.interfaces)
    ) nodes
  );

  # Create dummy interfaces for networking.interfaces entries that have no veth endpoint
  dummyCreateCommands = map (
    { nodeName, ifaceName }: "ip netns exec ${nodeName} ip link add ${ifaceName} type dummy"
  ) dummyIfaces;

  # Collect {ns, iface, addr} for all addresses of a given IP version.
  collectAddrs =
    getAddrs:
    lib.concatLists (
      lib.mapAttrsToList (
        nodeName: nodeCfg:
        lib.concatLists (
          lib.mapAttrsToList (
            ifaceName: ifaceCfg:
            map (a: {
              node = nodeName;
              iface = ifaceName;
              addr = "${a.address}/${toString a.prefixLength}";
            }) (getAddrs ifaceCfg)
          ) nodeCfg.networking.interfaces
        )
      ) nodes
    );

  ipv4Addrs = collectAddrs (ifaceCfg: ifaceCfg.ipv4.addresses);
  ipv6Addrs = collectAddrs (ifaceCfg: ifaceCfg.ipv6.addresses);

  mkAddrCommands =
    ipCmd: addrs:
    map (
      {
        node,
        iface,
        addr,
      }:
      "ip netns exec ${node} ${ipCmd} addr add ${addr} dev ${iface}"
    ) addrs;

  # Assign IPv4/IPv6 addresses
  ipv4AddrCommands = mkAddrCommands "ip" ipv4Addrs;
  ipv6AddrCommands = mkAddrCommands "ip -6" ipv6Addrs;

  # Bring veth interfaces up
  linkIfUpCommands = mkVethPairCmds (
    endpoint: "ip netns exec ${endpoint.node} ip link set ${endpoint.iface} up"
  );

  # Bring dummy interfaces up
  dummyIfUpCommands = map (
    { nodeName, ifaceName }: "ip netns exec ${nodeName} ip link set ${ifaceName} up"
  ) dummyIfaces;

  # Attach veth interfaces to bridge
  linkBridgeCommands = mkVethPairCmds (
    endpoint:
    lib.optionalString (builtins.elem endpoint.node config.bridges) "ip netns exec ${endpoint.node} ip link set ${endpoint.iface} master ${endpoint.node}"
  );

  # Configure MTU for all interfaces from networking.interfaces
  linkMtuCommands = lib.concatLists (
    lib.mapAttrsToList (
      nodeName: nodeCfg:
      lib.mapAttrsToList (
        ifaceName: ifaceCfg:
        let
          veth = getVeth nodeName ifaceName;
          mtu = resolveFirst "mtu" [
            ifaceCfg
            veth
            config
          ];
        in
        lib.optionalString (
          mtu != null
        ) "ip netns exec ${nodeName} ip link set ${ifaceName} mtu ${toString mtu}"
      ) nodeCfg.networking.interfaces
    ) nodes
  );

  # Configure ARP for veth endpoints
  linkArpCommands = map (
    veth:
    let
      arpA = resolveFirst "arp" [
        (getNodeIface veth.a)
        veth
        config
      ];
      arpB = resolveFirst "arp" [
        (getNodeIface veth.b)
        veth
        config
      ];
    in
    concatNonEmpty [
      (lib.optionalString (!arpA) "ip netns exec ${veth.a.node} ip link set ${veth.a.iface} arp off")
      (lib.optionalString (!arpB) "ip netns exec ${veth.b.node} ip link set ${veth.b.iface} arp off")
    ]
  ) veths;

  # Configure netem for veth pairs
  linkNetemCommands = map (
    veth:
    let
      ifaceA = getNodeIface veth.a;
      ifaceB = getNodeIface veth.b;
    in
    concatNonEmpty [
      (mkNetemCmd veth.a.node (resolveNetem veth.netem (ifaceA.netem or null)) (resolveFirst "mtu" [
        ifaceA
        veth
        config
      ]) veth.a.iface)
      (mkNetemCmd veth.b.node (resolveNetem veth.netem (ifaceB.netem or null)) (resolveFirst "mtu" [
        ifaceB
        veth
        config
      ]) veth.b.iface)
    ]
  ) veths;

  # Prefill ARP tables for veth pairs
  linkArpPrefillCommands = map (
    veth:
    let
      arpPrefillA = resolveFirst "arpPrefill" [
        (getNodeIface veth.a)
        veth
        config
      ];
      arpPrefillB = resolveFirst "arpPrefill" [
        (getNodeIface veth.b)
        veth
        config
      ];
      nodeA = "ip netns exec ${veth.a.node} ";
      nodeB = "ip netns exec ${veth.b.node} ";
      getIpv4s = node: (getNodeIface node).ipv4.addresses or [ ];
      # Get MAC from peer once, then add a neigh entry for each of its IPv4 addresses.
      mkPrefill =
        nodeLocal: localIface: nodePeer: peerIface: peerAddrs:
        lib.optionalString (peerAddrs != [ ]) (
          "_MAC=$(${nodePeer}cat /sys/class/net/${peerIface}/address)\n"
          + lib.concatStringsSep "\n" (
            map (a: "${nodeLocal}ip neigh add ${a.address} lladdr \"$_MAC\" dev ${localIface}") peerAddrs
          )
        );
    in
    concatNonEmpty [
      (lib.optionalString arpPrefillA (mkPrefill nodeA veth.a.iface nodeB veth.b.iface (getIpv4s veth.b)))
      (lib.optionalString arpPrefillB (mkPrefill nodeB veth.b.iface nodeA veth.a.iface (getIpv4s veth.a)))
    ]
  ) veths;

  # Build per-node route commands for one IP version.
  # ipCmd: "ip" or "ip -6"; getGw: nodeCfg -> gw|null; getRoutes: ifaceCfg -> list
  mkRouteCommands =
    ipCmd: getGw: getRoutes:
    lib.mapAttrsToList (
      nodeName: nodeCfg:
      let
        gw = getGw nodeCfg;
      in
      concatNonEmpty (
        lib.optional (gw != null) (
          "ip netns exec ${nodeName} ${ipCmd} route add default via ${gw.address}"
          + lib.optionalString (gw.interface != null) " dev ${gw.interface}"
          + lib.optionalString (gw.source != null) " src ${gw.source}"
          + lib.optionalString (gw.metric != null) " metric ${toString gw.metric}"
        )
        ++ lib.concatLists (
          lib.mapAttrsToList (
            ifaceName: ifaceCfg:
            map (
              route:
              "ip netns exec ${nodeName} ${ipCmd} route add ${route.address}/${toString route.prefixLength}"
              + lib.optionalString (route.via or null != null) " via ${route.via}"
              + " dev ${ifaceName}"
              + lib.concatStringsSep "" (lib.mapAttrsToList (k: v: " ${k} ${v}") (route.options or { }))
            ) (getRoutes ifaceCfg)
          ) nodeCfg.networking.interfaces
        )
      )
    ) nodes;

  # Declarative IPv4/IPv6 Routing
  ipv4RouteCommands = mkRouteCommands "ip" (nodeCfg: nodeCfg.networking.defaultGateway) (
    ifaceCfg: ifaceCfg.ipv4.routes
  );
  ipv6RouteCommands = mkRouteCommands "ip -6" (nodeCfg: nodeCfg.networking.defaultGateway6) (
    ifaceCfg: ifaceCfg.ipv6.routes
  );

  # Create bridge devices inside their own namespaces.
  bridgeAddCommands = map (
    brName: "ip netns exec ${brName} ip link add ${brName} type bridge stp_state 0"
  ) config.bridges;

  # Set bridges to up
  bridgeUpCommands = map (brName: "ip netns exec ${brName} ip link set ${brName} up") config.bridges;

  setupPhaseSections = lib.concatStringsSep "\n\n" (
    lib.filter (s: s != "") [
      (mkBashSection "pre-setup hook" [ config.preSetup ])
      (mkBashSection "create nodes" nodeCreateCommands)
      (mkBashSection "node pre-setup hooks" nodePreSetupCommands)
      (mkBashSection "sysctl settings" nodeSysctlCommands)
      (mkBashSection "create bridges" bridgeAddCommands)
      (mkBashSection "create veth pairs" vethCreateCommands)
      (mkBashSection "create dummy interfaces" dummyCreateCommands)
      (mkBashSection "assign ipv4 addresses" ipv4AddrCommands)
      (mkBashSection "assign ipv6 addresses" ipv6AddrCommands)
      (mkBashSection "attach interfaces to bridges" linkBridgeCommands)
      (mkBashSection "set bridges up" bridgeUpCommands)
      (mkBashSection "set interfaces up" (nodeLoUpCommands ++ linkIfUpCommands ++ dummyIfUpCommands))
      (mkBashSection "configure mtu" linkMtuCommands)
      (mkBashSection "configure arp" linkArpCommands)
      (mkBashSection "configure netem" linkNetemCommands)
      (mkBashSection "prefill arp" linkArpPrefillCommands)
      (mkBashSection "configure ipv4 routing" ipv4RouteCommands)
      (mkBashSection "configure ipv6 routing" ipv6RouteCommands)
      (mkBashSection "node post-setup hooks" nodePostSetupCommands)
      (mkBashSection "post-setup hook" [ config.postSetup ])
    ]
  );

  runPhaseSections = lib.concatStringsSep "\n\n" (
    lib.filter (s: s != "") [
      (mkBashSection "pre-run hook" [ config.preRun ])
      (mkBashSection "launch background scripts" nodeScripts.launchScripts)
      (mkBashSection "launch foreground scripts" nodeScripts.fgScripts)
      (lib.strings.trim ''
        # wait for background processes marked as await
        _FAILED=0
        for PID in "''${WAIT_PIDS[@]}"; do
          while kill -0 "$PID" 2>/dev/null; do
            sleep 0.1
          done
          _EXIT=0
          wait "$PID" 2>/dev/null || _EXIT=$?
          echo "testbed| PID $PID exited with $_EXIT"
          [ "$_EXIT" -eq 0 ] || _FAILED=1
          PIDS=("''${PIDS[@]/$PID}")
        done
        [ "$_FAILED" -eq 0 ] || exit 1
        stop_pids
      '')
      (mkBashSection "post-run hook" [ config.postRun ])
    ]
  );

  scriptText = ''
    #!${pkgs.bash}/bin/bash
    set -o errexit
    set -o nounset
    set -o pipefail

    set -m  # enable job control: each background job gets its own process group

    PIDS=()
    WAIT_PIDS=()
    _FAILED=0

    stop_pids() {
      for PID in "''${PIDS[@]}"; do
        [ -n "$PID" ] || continue
        if [ -e "/proc/$PID" ]; then
          kill -INT -- -"$PID" 2>/dev/null || true
          echo "testbed| PID $PID killed"
          _deadline=$((SECONDS + 5))
          while [ -e "/proc/$PID" ] && (( SECONDS < _deadline )); do
            sleep 0.1
          done
          if [ -e "/proc/$PID" ]; then
            kill -KILL -- -"$PID" 2>/dev/null || true
          fi
          wait "$PID" || true
        else
          _EXIT=0
          wait "$PID" || _EXIT=$?
          echo "testbed| PID $PID exited with $_EXIT"
          [ "$_EXIT" -eq 0 ] || _FAILED=1
        fi
      done
      PIDS=()
    }

    cleanup() {
      _FAILED=$?
      echo "testbed| cleaning up..."
      stop_pids
      exit "$_FAILED"
    }
    trap cleanup EXIT
    trap 'stop_pids; exit 130' INT TERM

    ${lib.optionalString (workDir != null && workDirEnsureEmpty) ''
      if [ -n "$(ls -A . 2>/dev/null)" ]; then
        echo "testbed| Error: workDir is not empty: $(pwd)"
        exit 1
      fi
    ''}
    ${lib.optionalString (workDir != null) ''
      _STORE_PATH="$(dirname "$(dirname "$0")")"
      ${writeRunJson} "$_STORE_PATH"
    ''}

    ${setupPhaseSections}

    echo "testbed| network topology set up"

    ${runPhaseSections}'';
in
{
  inherit scriptText tbAutoHostBinds;
  nodeScriptFiles = nodeScripts.nsScriptFiles;
  tbScriptFiles = nodeScripts.tbScriptFiles;
}
