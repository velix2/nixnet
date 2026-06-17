# Discovers test modules in testDirs and produces a runner script that executes
# each test, printing "name: pass" or "name: FAILED" and exiting 1 if any fail.
#
# A test module is any .nix file that takes { pkgs, ... }
# and returns either a single derivation or an attrset of derivations, where each
# derivation is a runnable script that exits 0 on pass and non-zero on fail.
{ pkgs, testDirs }:
let
  lib = pkgs.lib;

  allTests = lib.concatMap (
    dir:
    let
      files = lib.filterAttrs (
        n: t: t == "regular" && lib.hasSuffix ".nix" n
      ) (builtins.readDir dir);
    in
    lib.concatLists (
      lib.mapAttrsToList (
        _filename: _:
        let
          result = import (dir + "/${_filename}") { inherit pkgs; };
        in
        if lib.isDerivation result then
          [ result ]
        else if builtins.isAttrs result then
          lib.filter lib.isDerivation (lib.attrValues result)
        else if builtins.isList result && result != [ ] then
          throw "Eval tests failed (${_filename}):\n${builtins.toJSON result}"
        else
          [ ]
      ) files
    )
  ) testDirs;
in
pkgs.writeShellApplication {
  name = "test-runner";
  text = ''
    # Run tests with a clean store-only PATH, never the host's. Tests start
    # jails that mount only /nix/store, so a host tool (e.g. /usr/bin/grep on a
    # non-NixOS runner) leaked in via the inherited PATH would resolve on the
    # host but vanish inside the jail. Each test prepends its own runtimeInputs.
    export PATH=${lib.makeBinPath [
      pkgs.coreutils
      pkgs.gnused
    ]}

    _pass=0
    _fail=0

    _TIMEOUT=''${TEST_TIMEOUT:-60}

    run_test() {
      local _name="$1" _cmd="$2"
      local _output _rc=0 _start _end _secs
      _start=$SECONDS
      _output=$(timeout "$_TIMEOUT" "$_cmd" 2>&1) || _rc=$?
      _end=$SECONDS
      _secs=$((_end - _start))
      if [ "$_rc" -eq 0 ]; then
        echo "$_name: pass (''${_secs}s)"
        _pass=$((_pass + 1))
      elif [ "$_rc" -eq 124 ]; then
        echo "$_name: TIMEOUT (>''${_TIMEOUT}s)"
        printf '%s\n' "$_output" | sed 's/^/  /'
        _fail=$((_fail + 1))
      else
        echo "$_name: FAILED (''${_secs}s)"
        printf '%s\n' "$_output" | sed 's/^/  /'
        _fail=$((_fail + 1))
      fi
    }

    ${lib.concatMapStringsSep "\n" (drv: "run_test '${lib.getName drv}' '${lib.getExe drv}'") allTests}

    echo ""
    echo "$_pass passed, $_fail failed"
    [ "$_fail" -eq 0 ]
  '';
}
