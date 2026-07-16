{
  pkgs,
  jail-nix,
  jail_pkg,
}:

let
  lib = pkgs.lib;
  jail-exec-bin = pkgs.writeShellApplication {
    name = "jail-exec";
    runtimeInputs = [
      jail_pkg
      pkgs.bash
      pkgs.coreutils
    ];
    text = ''
      ${jail_pkg}/bin/jail exec "$@"
    '';
  };
  jail-add-bin =
    jailname:
    pkgs.writeShellApplication {
      name = "jail-add-${jailname}";
      runtimeInputs = [
        jail_pkg
        pkgs.bash
        pkgs.coreutils
      ];
      text = ''
        _args=()
          while [ "$1" != "--" ]; do
            _args+=("$1")
            shift
          done

        ${jail_pkg}/bin/jail add ${jailname} "''${_args[@]}"
      '';
    };
in
{
  outer-jail = jail-nix.lib.extend {
    inherit pkgs;
    additionalCombinators =
      builtinCombinators: with builtinCombinators; {
        # Temporary compatibility layer for translating old flags to new combinators
        compat-translate-flags =
          let
            trimQuotes = s: pkgs.lib.removePrefix "\"" (pkgs.lib.removeSuffix "\"" s);
          in
          flags_list:
          compose (
            map (
              flag:
              let
                flag_params = pkgs.lib.splitString " " (pkgs.lib.trim flag);
                cmd = pkgs.lib.trim (builtins.elemAt flag_params 0);
              in
              builtins.trace "parsing flag ${flag}" (
                if cmd == "--bind" then
                  unsafe-add-raw-args (
                    "--bind \""
                    + (trimQuotes (builtins.elemAt flag_params 1))
                    + "\" \""
                    + (trimQuotes (builtins.elemAt flag_params 2))
                    + "\""
                  )
                else if cmd == "--ro-bind" then
                  unsafe-add-raw-args (
                    "--ro-bind \""
                    + (trimQuotes (builtins.elemAt flag_params 1))
                    + "\" \""
                    + (trimQuotes (builtins.elemAt flag_params 2))
                    + "\""
                  )
                else if cmd == "--setenv" then
                  let
                    setenv_args = pkgs.lib.splitString "=" (trimQuotes (builtins.elemAt flag_params 1));
                    env_name = builtins.elemAt setenv_args 0;
                    env_value = builtins.elemAt setenv_args 1;
                  in
                  builtins.trace
                    "outer-jail: translating --setenv env_name=${env_name}, env_value=${env_value} to set-env combinator"
                    (
                      #  set-env env_name env_value
                      unsafe-add-raw-args "--setenv ${env_name} \"${env_value}\""
                    )
                else if cmd == "--chdir" then
                  unsafe-add-raw-args "--chdir \"${trimQuotes (builtins.elemAt flag_params 1)}\""
                else if cmd == "--wayland" then
                    wayland
                else
                  throw "outer-jail: unknown flag ${flag}"
              )
            ) flags_list
          );
      };

    basePermissions =
      combinators: with combinators; [
        (unsafe-add-raw-args "--dev /dev") # For /dev/null during jail's setup
        (unsafe-add-raw-args "--proc /proc") # For jail's setup
        (unsafe-add-raw-args "--tmpfs /tmp") # For creating inner jail's root dir
        (add-pkg-deps [
          jail_pkg # For calling jail add/enter from within
          pkgs.coreutils
          pkgs.iproute2
          pkgs.procps
          pkgs.gnused
          pkgs.bash # For post setup hook
        ])
        bind-nix-store-runtime-closure
        fake-passwd
      ];
    bubblewrapPackage = jail-exec-bin;
  };

  inner-jail =
    jailname:
    let
      baseJail = (
        jail-nix.lib.extend {
          inherit pkgs;
          basePermissions =
            combinators: with combinators; [
              (unsafe-add-raw-args "--dev /dev")
              (unsafe-add-raw-args "--proc /proc")
              (unsafe-add-raw-args "--tmpfs /tmp")
              (write-text "/etc/hostname" "${jailname}\n")
              fake-passwd
              bind-nix-store-runtime-closure
              (add-pkg-deps [
                jail_pkg
              ])
            ];
          bubblewrapPackage = jail-add-bin jailname;

          additionalCombinators =
            builtinCombinators: with builtinCombinators; {
              # Temporary compatibility layer for translating old flags to new combinators
              compat-translate-flags =
                let
                  trimQuotes = s: pkgs.lib.removePrefix "\"" (pkgs.lib.removeSuffix "\"" s);
                in
                flags_list:
                let
                  valid_flags = builtins.filter (f: pkgs.lib.trim f != "") flags_list;
                in
                compose (
                  map (
                    flag:
                    let
                      flag_params = builtins.filter (x: x != "") (pkgs.lib.splitString " " (pkgs.lib.trim flag));
                      cmd = pkgs.lib.trim (builtins.elemAt flag_params 0);
                    in
                    if cmd == "--bind" then
                      unsafe-add-raw-args (
                        "--bind \""
                        + (trimQuotes (builtins.elemAt flag_params 1))
                        + "\" \""
                        + (trimQuotes (builtins.elemAt flag_params 2))
                        + "\""
                      )
                    else if cmd == "--ro-bind" then
                      unsafe-add-raw-args (
                        "--ro-bind \""
                        + (trimQuotes (builtins.elemAt flag_params 1))
                        + "\" \""
                        + (trimQuotes (builtins.elemAt flag_params 2))
                        + "\""
                      )
                    else if cmd == "--setenv" then
                      let
                        rest = builtins.concatStringsSep " " (pkgs.lib.drop 1 flag_params);
                        setenv_args = pkgs.lib.splitString "=" (trimQuotes rest);
                        env_name = builtins.elemAt setenv_args 0;
                        env_value = builtins.elemAt setenv_args 1;
                      in
                      unsafe-add-raw-args "--setenv ${env_name} \"${env_value}\""
                    else if cmd == "--chdir" then
                      unsafe-add-raw-args "--chdir \"${trimQuotes (builtins.elemAt flag_params 1)}\""
                    else if cmd == "--wayland" then
                        wayland
                    else
                      throw "outer-jail: unknown flag '${flag}'"
                  ) valid_flags
                );

              bind-node-script-files =
                nodeScriptFiles: nodeName: nodeCfg:
                compose (
                  lib.mapAttrsToList (
                    scriptName: _scriptCfg:
                    let
                      scriptFile = nodeScriptFiles.${nodeName}.${scriptName};
                    in
                    (unsafe-add-raw-args "--ro-bind ${scriptFile} ${scriptFile}")
                  ) nodeCfg.scripts
                );
            };
        }
      );
    in
    {
      # Expose the combinators as an attribute on this set
      combinators = baseJail.combinators;

      # Use __functor to make the set callable like a function (preserve original behavior)
      __functor = self: baseJail "jail-add-${jailname}" (pkgs.writeShellScriptBin "_" "");
    };
}
