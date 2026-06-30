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
        gnugrep
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
  test-jail-sigint-direct = ''
    # A direct SIGINT to the outer jail process exits it promptly.
    jail exec --setenv "PATH=$PATH" bash -c "
      exec sleep 5
    " &
    PID=$!
    sleep 0.2
    kill -INT "$PID"
    T=$SECONDS
    wait "$PID" || true
    (( SECONDS - T < 3 )) || fail "direct SIGINT: jail did not exit promptly"
    pass "direct SIGINT exits the jail"
  '';

  test-jail-sigint-job-control-wait = ''
    # SIGINT exits a jail that is waiting on a background nested enter via job control.
    jail exec --setenv "PATH=$PATH" bash -c "
      jail add --setenv PATH=$PATH myjail
      set -m
      jail enter myjail bash -c \"sleep 5\" &
      wait \$!
    " &
    PID=$!
    sleep 0.2
    kill -INT "$PID"
    T=$SECONDS
    wait "$PID" || true
    (( SECONDS - T < 3 )) || fail "job-control wait: jail did not exit promptly on SIGINT"
    pass "SIGINT exits a job-control wait"
  '';

  test-jail-sigint-term-trap = ''
    # A TERM trap interrupts a job-control wait immediately on SIGINT.
    jail exec --setenv "PATH=$PATH" bash -c "
      set -m
      trap 'exit 130' INT TERM
      sleep 30 &
      wait \$!
    " &
    PID=$!
    sleep 0.2
    kill -INT "$PID"
    T=$SECONDS
    wait "$PID" || true
    (( SECONDS - T < 3 )) || fail "TERM trap: did not exit promptly during job-control wait"
    pass "TERM trap interrupts a job-control wait"
  '';

  test-jail-sigint-process-group = ''
    # Sending SIGINT to the jail's process group (as a terminal Ctrl+C does) exits the jail.
    set -m
    jail exec --setenv "PATH=$PATH" bash -c "
      set -m
      PIDS=()
      WAIT_PIDS=()
      stop_pids() {
        for P in \"\''${PIDS[@]}\"; do
          [ -n \"\$P\" ] || continue
          [ -e \"/proc/\$P\" ] || continue
          kill -INT -- -\"\$P\" 2>/dev/null || true
          wait \"\$P\" 2>/dev/null || true
        done
        PIDS=()
      }
      trap 'stop_pids; exit 130' INT TERM
      ( set +m; sleep 30 ) &
      PIDS+=(\$!)
      WAIT_PIDS+=(\$!)
      for P in \"\''${WAIT_PIDS[@]}\"; do
        while kill -0 \"\$P\" 2>/dev/null; do
          sleep 0.1
        done
      done
    " &
    PID=$!
    set +m
    sleep 0.5
    kill -INT -- -"$PID"
    T=$SECONDS
    wait "$PID" || true
    (( SECONDS - T < 3 )) || fail "process-group SIGINT: testbed did not exit promptly"
    pass "process-group SIGINT (Ctrl+C) exits the jail"
  '';

  test-jail-sigint-nested-inner = ''
    # SIGINT to an outer jail reaches the inner process of a nested named jail so it
    # can run its cleanup trap.
    PIPE=$(mktemp /tmp/jail_test_XXXXXX)
    trap 'rm -f "$PIPE"' EXIT
    jail exec --setenv "PATH=$PATH" --bind "$PIPE" "$PIPE" bash -c "
      jail add --setenv PATH=$PATH --bind $PIPE $PIPE myjail
      jail enter myjail bash -c \"
      trap 'echo signal >> $PIPE; exit 0' TERM INT
      echo ready >> $PIPE
      sleep 5
      \"
    " &
    PID=$!
    until grep -q ready "$PIPE" 2>/dev/null; do sleep 0.05; done
    kill -INT "$PID"
    T=$SECONDS
    wait "$PID" || true
    grep -q signal "$PIPE" || fail "nested inner: signal was not delivered"
    (( SECONDS - T < 3 )) || fail "nested inner: jail did not exit promptly"
    pass "SIGINT reaches the nested inner process"
  '';

  test-jail-sigint-init-signal = ''
    # Signalling a named jail's init gracefully destroys the jail — the inner process
    # runs its cleanup trap before the namespace is torn down.
    PIPE=$(mktemp /tmp/jail_test_XXXXXX)
    trap 'rm -f "$PIPE"' EXIT
    jail exec --setenv "PATH=$PATH" --bind "$PIPE" "$PIPE" bash -c "
      jail add --setenv PATH=$PATH --bind $PIPE $PIPE myjail
      jail enter myjail bash -c \"
      trap 'echo signal >> $PIPE; exit 0' TERM INT
      echo ready >> $PIPE
      sleep 5
      \" &
      until grep -q ready $PIPE 2>/dev/null; do sleep 0.05; done
      kill -INT \"\$(cat /run/jail/myjail/pid)\"
      T=\$SECONDS
      wait
      (( SECONDS - T >= 3 )) && { echo slow >> $PIPE; }
    " &
    PID=$!
    wait "$PID" || true
    grep -q signal "$PIPE" || fail "signal init: inner process did not get the signal"
    grep -q slow "$PIPE" && fail "signal init: jail did not tear down promptly"
    pass "signalling init destroys the jail"
  '';

  test-jail-sigint-concurrent-enters = ''
    # Two concurrent enters in one named jail run independently and both complete.
    PIPE=$(mktemp /tmp/jail_test_XXXXXX)
    trap 'rm -f "$PIPE"' EXIT
    T=$SECONDS
    jail exec --setenv "PATH=$PATH" --bind "$PIPE" "$PIPE" bash -c "
      jail add --setenv PATH=$PATH --bind $PIPE $PIPE myjail
      jail enter myjail bash -c 'sleep 1; echo done2 >> $PIPE' &
      jail enter myjail bash -c 'sleep 2; echo done3 >> $PIPE' &
      wait
    "
    { grep -q done2 "$PIPE" && grep -q done3 "$PIPE"; } || fail "concurrent enters: both should complete"
    (( SECONDS - T < 4 )) || fail "concurrent enters: ran serially, expected concurrent"
    pass "concurrent enters run independently"
  '';

  test-jail-sigint-isolated-kill = ''
    # Killing one enter tears down only that command; the other enter in the same jail
    # keeps running to completion.
    PIPE=$(mktemp /tmp/jail_test_XXXXXX)
    trap 'rm -f "$PIPE"' EXIT
    jail exec --setenv "PATH=$PATH" --bind "$PIPE" "$PIPE" bash -c "
      jail add --setenv PATH=$PATH --bind $PIPE $PIPE myjail
      jail enter myjail bash -c 'sleep 1; echo done2 >> $PIPE' &
      P_KILL=\$!
      jail enter myjail bash -c 'sleep 2; echo done3 >> $PIPE' &
      sleep 0.5
      kill \$P_KILL
      wait
    "
    grep -q done2 "$PIPE" && fail "isolated kill: killed enter kept running instead of terminating"
    grep -q done3 "$PIPE" || fail "isolated kill: killing one enter affected another in the same jail"
    pass "killing one enter leaves the others running"
  '';

  test-jail-sigint-sigkill-fallback = ''
    # A child that catches SIGTERM and refuses to exit is still killed when the jail
    # is destroyed — the jail does not hang.
    PIPE=$(mktemp /tmp/jail_test_XXXXXX)
    trap 'rm -f "$PIPE"' EXIT
    T=$SECONDS
    jail exec --setenv "PATH=$PATH" --bind "$PIPE" "$PIPE" bash -c "
      jail add --setenv PATH=$PATH --bind $PIPE $PIPE myjail
      jail enter myjail bash -c \"
        trap 'echo got-term >> $PIPE' TERM
        trap : INT
        echo ready >> $PIPE
        while true; do sleep 0.2; done
      \" 2>/dev/null &
      until grep -q ready $PIPE 2>/dev/null; do sleep 0.05; done
      kill -INT \"\$(cat /run/jail/myjail/pid)\"
      wait
    "
    DUR=$((SECONDS - T))
    grep -q got-term "$PIPE" || fail "SIGKILL fallback: child never received SIGTERM from init"
    (( DUR >= 4 )) || fail "SIGKILL fallback: torn down too fast — a SIGTERM-ignoring child should force the deadline"
    (( DUR < 8 )) || fail "SIGKILL fallback: jail hung; init did not SIGKILL the unresponsive child"
    pass "SIGTERM-ignoring child is SIGKILLed"
  '';

  test-jail-sigint-enter-kill = ''
    # Killing a jail enter delivers SIGTERM to its inner command. If the inner command
    # ignores SIGTERM it is eventually killed. Other enters in the same jail are unaffected.
    PIPE=$(mktemp /tmp/jail_test_XXXXXX)
    trap 'rm -f "$PIPE"' EXIT
    T=$SECONDS
    jail exec --setenv "PATH=$PATH" --bind "$PIPE" "$PIPE" bash -c "
      jail add --setenv PATH=$PATH --bind $PIPE $PIPE myjail
      jail enter myjail bash -c \"
        trap 'echo got-term >> $PIPE' TERM
        trap : INT
        echo ready >> $PIPE
        while true; do sleep 0.2; done
      \" &
      ENTER1=\$!
      jail enter myjail bash -c 'sleep 1; echo done2 >> $PIPE' &
      ENTER2=\$!
      until grep -q ready $PIPE 2>/dev/null; do sleep 0.05; done
      kill \$ENTER1
      wait \$ENTER1 || true
      wait \$ENTER2 || true
      kill -INT \"\$(cat /run/jail/myjail/pid)\"
      wait
    "
    DUR=$((SECONDS - T))
    grep -q got-term "$PIPE" || fail "enter kill: inner command never received SIGTERM"
    grep -q done2 "$PIPE" || fail "enter kill: killing one enter affected another in the same jail"
    (( DUR < 10 )) || fail "enter kill: inner cmd not killed within deadline (''${DUR}s); SIGKILL fallback should fire within 5 s"
    pass "killing a jail enter delivers SIGTERM to its inner command and SIGKILLs if unresponsive; other enters are unaffected"
  '';

  test-jail-sigint-exit-code = ''
    # A jail enter's exit code propagates back through jail exec to the caller.
    code=0
    jail exec --setenv "PATH=$PATH" bash -c "
      jail add --setenv PATH=$PATH myjail
      jail enter myjail bash -c 'exit 37'
      exit \$?
    " || code=$?
    (( code == 37 )) || fail "exit code: expected 37 to propagate, got $code"
    pass "exit codes propagate to the caller"
  '';
}
