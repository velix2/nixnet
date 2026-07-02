{
  pkgs,
  jail-nix,
  jail_pkg,
}:

let
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
        ${jail_pkg}/bin/jail add ${jailname} "$@"
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
                flag_params = pkgs.lib.splitString " " flag;
                cmd = builtins.elemAt flag_params 0;
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
              else
                throw "outer-jail: unknown flag ${flag}"
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
        ])
        bind-nix-store-runtime-closure
      ];
    bubblewrapPackage = jail-exec-bin;
  };

  inner-jail =
    jailname:
    jail-nix.lib.extend {
      inherit pkgs;
      basePermissions =
        combinators: with combinators; [
          (unsafe-add-raw-args "--dev /dev")
          (unsafe-add-raw-args "--proc /proc") # For jail's setup
          bind-nix-store-runtime-closure
          (add-pkg-deps [
            jail_pkg # For init
          ])
        ];
      bubblewrapPackage = jail-add-bin jailname;
    };
}
