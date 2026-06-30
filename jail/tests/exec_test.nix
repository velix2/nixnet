{
  pkgs,
  jail ? pkgs.callPackage ../pkgs/jail.nix { },
}:
let
  lib = pkgs.lib;

  mkTest =
    name: text:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = with pkgs; [
        coreutils
        bash
        jail
      ];
      text = ''
        pass() { echo "PASS: $*"; }
        fail() { echo "FAIL: $*"; exit 1; }

        ${text}
      '';
    };
in
lib.mapAttrs mkTest {
  test-jail-exec-add-enter = ''
    # The basic exec → add → enter workflow works: a command inside a nested
    # named jail runs in the sandboxed environment.
    jail exec --setenv "PATH=$PATH" bash -c "
      jail add --setenv PATH=$PATH myjail
      jail enter myjail bash -c 'cat /etc/hostname'
    "
    pass "exec add enter works"
  '';
}
