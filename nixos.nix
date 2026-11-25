{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.droidloom;
  droidloom = pkgs.callPackage ./package.nix { };
  home = config.users.users.${cfg.user}.home;
  jq = lib.getExe pkgs.jq;
  inherit (lib) escapeShellArg;

  absoluteDirectory = lib.types.addCheck lib.types.str (
    path:
    lib.hasPrefix "/" path
    && lib.all (part: part != "" && part != "." && part != "..") (
      lib.splitString "/" (lib.removePrefix "/" path)
    )
  );
  storageDirectory = lib.types.addCheck absoluteDirectory (lib.hasPrefix "/var/lib/droidloom/");

  setup = pkgs.writeShellScript "droidloom-setup" ''
    set -euo pipefail
    conflict=0
    for name in ${lib.escapeShellArgs (builtins.attrNames compatLinks)}; do
      if [[ $(readlink -- "/usr/$name" || true) != "/etc/droidloom/compat/$name" ]]; then
        echo "Droidloom needs /usr/$name -> /etc/droidloom/compat/$name; the existing path, if any, was left untouched." >&2
        conflict=1
      fi
    done
    (( conflict == 0 )) || exit 1

    uid=$(id -u -- ${escapeShellArg cfg.user})
    args=(setup --uid "$uid" --data-home ${escapeShellArg "${home}/.local/share"}
          --state-home ${escapeShellArg "${home}/.local/state"})
    helper=${droidloom}/usr/lib/droidloom/droidloom-package-helper
    base=/var/lib/droidloom/users/$uid
    vanilla=${escapeShellArg (if cfg.dataDirectory == null then "" else cfg.dataDirectory)}
    google=${escapeShellArg (if cfg.gapps.dataDirectory == null then "" else cfg.gapps.dataDirectory)}
    addon=${
      escapeShellArg (if cfg.gapps.enable && cfg.gapps.directory != null then cfg.gapps.directory else "")
    }
    vanilla=''${vanilla:-$base/data}
    google=''${google:-$base/data-gapps}
    if [[ $vanilla == "$google" || $vanilla == "$google/"* || $google == "$vanilla/"* ]]; then
      echo 'Droidloom needs separate vanilla and GApps storage directories.' >&2
      exit 1
    fi
    if [[ -n $addon && ! -f $addon/manifest.json ]]; then
      echo "No Droidloom GApps manifest at $addon/manifest.json" >&2
      exit 1
    fi

    "$helper" "''${args[@]}"
    cd /etc/droidloom
    exec ${lib.getExe pkgs.bash} ${./switch-storage.sh} ${./select-storage.jq} \
      "$vanilla" "$google" "$addon" "$helper" "''${args[@]}"
  '';

  # Keep the helper's spec intact: `droidloomctl start` would reset a backend
  # it didn't select. Apply the workaround only at Android namespace entry.
  supervisor = pkgs.writeShellScript "droidloom-supervisor" ''
    set -eu
    if [[ $# == 3 && $1 == development-enter && $2 == --spec ]]; then
      node=$(${jq} -er 'if (.graphics_backend // "drm") == "drm" then .render_node else "" end' "$3")
      device=/sys/class/drm/''${node##*/}/device
      # The bundled minigbm xe backend rejects Intel device 8086:e20b.
      if [[ $node == /dev/dri/renderD* && -r $device/vendor && -r $device/device ]] &&
         [[ $(<"$device/vendor") == 0x8086 && $(<"$device/device") == 0xe20b ]]; then
        spec=/run/droidloom/allocator-cell.json
        (umask 077; ${jq} -c '.graphics_backend = "drm_dma_heap"' "$3" > "$spec")
        set -- development-enter --spec "$spec"
      fi
    fi
    exec ${droidloom}/usr/bin/droidloom-supervisor "$@"
  '';

  # Stable destinations let upgrades update the private link farm, not /usr.
  compatLinks =
    lib.genAttrs [
      "bin/droidloom-applications"
      "bin/droidloom-audio"
      "bin/droidloom-devices"
      "bin/droidloom-doctor"
      "bin/droidloom-gpu-server"
      "bin/droidloom-supervisor"
      "bin/droidloom-wayland"
      "bin/droidloomctl"
      "bin/droidloomd"
      "lib/droidloom"
      "share/droidloom"
    ] (name: "${droidloom}/usr/${name}")
    // {
      "bin/getent" = "${pkgs.glibc.getent}/bin/getent";
      "bin/pkexec" = "${config.security.wrapperDir}/pkexec";
      "bin/runuser" = "${pkgs.util-linux}/bin/runuser";
      "bin/nsenter" = "${pkgs.util-linux}/bin/nsenter";
      "bin/systemctl" = "${pkgs.systemd}/bin/systemctl";
      "bin/systemd-run" = "${pkgs.systemd}/bin/systemd-run";
      "bin/timeout" = "${pkgs.coreutils}/bin/timeout";
      "bin/adb" = "${pkgs.android-tools}/bin/adb";
      "bin/cat" = "${pkgs.coreutils}/bin/cat";
    };
in
{
  options.services.droidloom = {
    enable = lib.mkEnableOption "Droidloom";
    user = lib.mkOption {
      type = lib.types.str;
      description = "Existing desktop user who owns the Droidloom cell.";
    };
    enableDmaHeap = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable the system DMA-BUF heap in the kernel. Disable to use an already configured kernel.";
    };
    dataDirectory = lib.mkOption {
      type = lib.types.nullOr storageDirectory;
      default = null;
      description = "Vanilla Android storage directory. Defaults to /var/lib/droidloom/users/<uid>/data.";
    };
    gapps = {
      enable = lib.mkEnableOption "a locally built Droidloom Google apps add-on";
      directory = lib.mkOption {
        type = lib.types.nullOr absoluteDirectory;
        default = null;
        description = "Root-owned directory containing the add-on manifest and images, with no symlink or writable ancestors.";
      };
      dataDirectory = lib.mkOption {
        type = lib.types.nullOr storageDirectory;
        default = null;
        description = "Separate Google apps storage directory. Defaults to /var/lib/droidloom/users/<uid>/data-gapps.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.user != "root" && (config.users.users.${cfg.user}.isNormalUser or false);
        message = "services.droidloom.user must name an existing normal user.";
      }
      {
        assertion = !cfg.gapps.enable || cfg.gapps.directory != null;
        message = "services.droidloom.gapps.enable requires services.droidloom.gapps.directory.";
      }
      {
        assertion = cfg.dataDirectory == null || cfg.dataDirectory != cfg.gapps.dataDirectory;
        message = "Droidloom needs separate vanilla and GApps storage directories.";
      }
    ];

    security.polkit.enable = true;
    boot.kernelPatches = lib.optionals cfg.enableDmaHeap [
      {
        name = "droidloom-dma-heap";
        patch = null;
        structuredExtraConfig = {
          DMABUF_HEAPS = lib.kernel.yes;
          DMABUF_HEAPS_SYSTEM = lib.kernel.yes;
        };
      }
    ];

    environment.systemPackages = [
      droidloom
      pkgs.nftables
    ];

    environment.etc."droidloom/compat".source = pkgs.linkFarm "droidloom-compat" compatLinks;
    systemd.tmpfiles.rules = map (name: "L /usr/${name} - - - - /etc/droidloom/compat/${name}") (
      builtins.attrNames compatLinks
    );

    systemd.services.droidloom-setup = {
      description = "Configure Droidloom for ${cfg.user}";
      wantedBy = [ "multi-user.target" ];
      before = [ "droidloomd.service" ];
      after = [
        "local-fs.target"
        "systemd-tmpfiles-setup.service"
      ];
      path = [
        pkgs.jq
        pkgs.util-linux
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${setup}";
      };
    };

    systemd.services.droidloomd = {
      description = "Droidloom Android cell lifecycle daemon";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network.target"
        "systemd-tmpfiles-setup.service"
        "droidloom-setup.service"
      ];
      requires = [ "droidloom-setup.service" ];
      restartTriggers = [ setup ];
      path = with pkgs; [
        gnutar
        nftables
        iproute2
        iptables
        util-linux
        zstd
      ];
      serviceConfig = {
        ExecStart = "${droidloom}/usr/bin/droidloomd --supervisor ${supervisor}";
        # Give Android separate cgroups for services and apps.
        Delegate = "memory pids";
        DelegateSubgroup = "supervisor";
        Type = "simple";
        TimeoutStopSec = "20s";
        KillMode = "mixed";
        OOMPolicy = "continue";
        Restart = "on-failure";
        RestartSec = "1s";
        RuntimeDirectory = "droidloom";
        RuntimeDirectoryMode = "0755";
      };
    };
  };
}
