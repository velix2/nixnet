pkgs:
let
  template = pkgs.writeText "template.tera" ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail

    {%- if SHARE_PATH == "true" %}
    export ORIG_PATH="$PATH"
    {%- endif %}

    # PATH for wrapper script
    _PATH="" # clear path
    _PATH="${pkgs.bash}/bin:$_PATH"
    _PATH="${pkgs.coreutils}/bin:$_PATH"
    _PATH="${pkgs.util-linux}/bin:$_PATH"
    export PATH="$_PATH"

    export ORIG_PWD="$PWD"
    export REAL_UID="''${REAL_UID:-$(id -u)}"

    UNSHARE_ARGS=(
      --keep-caps
      --mount
      --uts
      --ipc
      --cgroup
      {%- if SHARE_PID != "true" %}
      --pid
      --fork
      {%- endif %}
    )
    {%- if TESTBED == "true" %}
    if [ "$REAL_UID" != "0" ]; then
      UNSHARE_ARGS+=(
        --user
        --map-root-user
      )
    fi
    {%- endif %}

    exec unshare "''${UNSHARE_ARGS[@]}" -- bash -c '
      set -euo pipefail

      {%- if TESTBED == "true" or SHARE_MOUNT != "true" %}
      mount --make-rprivate /

      NEWROOT=$(mktemp -d)
      mount -t tmpfs tmpfs "$NEWROOT"

      mkdir -p "$NEWROOT/nix/store"
      mkdir -p "$NEWROOT/sys"
      mkdir -p "$NEWROOT/dev"
      mkdir -p "$NEWROOT/proc"
      mkdir -p "$NEWROOT/tmp"
      mkdir -p "$NEWROOT/var/run/netns"
      mkdir -p "$NEWROOT/bin"
      mkdir -p "$NEWROOT/etc"

      printf "root:x:0:0:root:/root:/bin/sh\n" > "$NEWROOT/etc/passwd"
      printf "nobody:x:65534:65534:nobody:/var/empty:/bin/sh\n" >> "$NEWROOT/etc/passwd"
      printf "root:x:0:\n" > "$NEWROOT/etc/group"
      printf "nobody:x:65534:\n" >> "$NEWROOT/etc/group"
      printf "nogroup:x:65534:\n" >> "$NEWROOT/etc/group"

      mount --bind /nix/store "$NEWROOT/nix/store"
      mount --rbind /sys "$NEWROOT/sys"

      mount -t tmpfs tmpfs "$NEWROOT/dev" -o mode=755
      touch "$NEWROOT/dev/null"
      touch "$NEWROOT/dev/zero"
      touch "$NEWROOT/dev/urandom"
      touch "$NEWROOT/dev/random"
      mount --bind /dev/null "$NEWROOT/dev/null"
      mount --bind /dev/zero "$NEWROOT/dev/zero"
      mount --bind /dev/urandom "$NEWROOT/dev/urandom"
      mount --bind /dev/random "$NEWROOT/dev/random"

      mkdir -p "$NEWROOT/dev/shm"
      mount -t tmpfs tmpfs "$NEWROOT/dev/shm" -o mode=1777

      mkdir -p "$NEWROOT/dev/pts"
      mount -t devpts devpts "$NEWROOT/dev/pts" -o newinstance,ptmxmode=0666
      ln -sf /dev/pts/ptmx "$NEWROOT/dev/ptmx"

      ln -s /proc/self/fd "$NEWROOT/dev/fd"
      ln -s /proc/self/fd/0 "$NEWROOT/dev/stdin"
      ln -s /proc/self/fd/1 "$NEWROOT/dev/stdout"
      ln -s /proc/self/fd/2 "$NEWROOT/dev/stderr"

      mount -t proc proc "$NEWROOT/proc"
      mount -t tmpfs tmpfs "$NEWROOT/tmp"
      mount -t tmpfs tmpfs "$NEWROOT/var/run/netns"

      ln -s "${pkgs.bash}/bin/sh" "$NEWROOT/bin/sh"

      mkdir -p "$NEWROOT$ORIG_PWD"
      {%- if BIND_PWD == "true" %}
      mount --bind "$ORIG_PWD" "$NEWROOT$ORIG_PWD"
      {%- endif %}

      {%- if SHARE_WAYLAND == "true" %}
      mkdir -p "$NEWROOT$XDG_RUNTIME_DIR"
      if [ -n "''${WAYLAND_DISPLAY:-}" ]; then
        touch "$NEWROOT$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
        mount --rbind "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" "$NEWROOT$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
      fi
      if [ -e /dev/dri ]; then
        mkdir -p "$NEWROOT/dev/dri"
        mount --bind /dev/dri "$NEWROOT/dev/dri"
      fi
      if [ -d /run/opengl-driver ]; then
        mkdir -p "$NEWROOT/run/opengl-driver"
        mount --bind /run/opengl-driver "$NEWROOT/run/opengl-driver"
      fi
      {%- endif %}

      mkdir -p "$NEWROOT/.oldroot"
      cd "$NEWROOT"
      pivot_root . .oldroot
      umount -l /.oldroot
      rmdir /.oldroot
      {%- endif %}
      cd "$ORIG_PWD"

      {%- if SHARE_PATH == "true" %}
      _PATH="$ORIG_PATH" # inherit path
      {%- else %}
      _PATH="" # clear path
      {%- endif %}
      {%- if WRAP_PATH %}
      {%- for dir in WRAP_PATH | split(pat=":") %}
      _PATH="{{ dir }}:$_PATH"
      {%- endfor %}
      {%- endif %}

      {%- if TESTBED == "true" %}
      UNSHARE_ARGS=(
        --mount
        --net
        --keep-caps
      )
      if [ "$REAL_UID" != "0" ]; then
        UNSHARE_ARGS+=(
          --user
          --map-root-user
        )
      fi
      exec unshare "''${UNSHARE_ARGS[@]}" -- env -i \
        HOME=/tmp \
        USER=root \
        REAL_UID="$REAL_UID" \
        PATH="$_PATH" \
        TERM="''${TERM:-}" \
        {%- if SHARE_WAYLAND == "true" %}
        XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
        NIXOS_OZONE_WL="''${NIXOS_OZONE_WL:-}" \
        XDG_SESSION_TYPE="''${XDG_SESSION_TYPE:-}" \
        DISPLAY="''${DISPLAY:-}" \
        WAYLAND_DISPLAY="''${WAYLAND_DISPLAY:-}" \
        {%- endif %}
        "$0" "$@"
      {%- elif SHARE_ENV == "true" %}
      export PATH="$_PATH"
      exec "$0" "$@"
      {%- else %}
      exec env -i \
        HOME=/tmp \
        USER=user \
        REAL_UID="$REAL_UID" \
        PATH="$_PATH" \
        TERM="''${TERM:-}" \
        {%- if SHARE_WAYLAND == "true" %}
        XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
        NIXOS_OZONE_WL="''${NIXOS_OZONE_WL:-}" \
        XDG_SESSION_TYPE="''${XDG_SESSION_TYPE:-}" \
        DISPLAY="''${DISPLAY:-}" \
        WAYLAND_DISPLAY="''${WAYLAND_DISPLAY:-}" \
        {%- endif %}
        "$0" "$@"
      {%- endif %}
    ' "{{ HIDDEN }}" "$@"
  '';
in
pkgs.writeShellScriptBin "wrap" ''
  set -euo pipefail
  prog="$1"
  export TESTBED=false
  export SHARE_PATH=false
  export BIND_PWD=false
  export SHARE_ENV=false
  export SHARE_MOUNT=false
  export WRAP_PATH="$2"
  export SHARE_WAYLAND=false
  export SHARE_PID=false

  for arg in "''${@:3}"; do
    case "$arg" in
      --testbed) TESTBED=true ;;
      --share-path) SHARE_PATH=true ;;
      --bind-pwd) BIND_PWD=true ;;
      --share-env) SHARE_ENV=true ;;
      --share-mount) SHARE_MOUNT=true ;;
      --share-wayland) SHARE_WAYLAND=true ;;
      --share-pid) SHARE_PID=true ;;
    esac
  done

  export HIDDEN="$(dirname "$prog")/.$(basename "$prog")-wrapped"
  while [ -e "$HIDDEN" ]; do
      HIDDEN="''${HIDDEN}_"
  done
  mv "$prog" "$HIDDEN"
  ${pkgs.tera-cli}/bin/tera -t ${template} --env-only > "$prog"
  chmod +x "$prog"
''
