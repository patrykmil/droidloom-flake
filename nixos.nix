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
    changed=$(
      set -e
      cd /etc/droidloom
      exec 9>> setup.lock
      flock -x 9
      previous=$(${jq} -c . cell.json)
      selected=$(${jq} -c --arg vanilla "$vanilla" --arg google "$google" --arg addon "$addon" \
        -f ${./select-storage.jq} cell.json)
      if [[ $previous != "$selected" ]]; then
        next=$(mktemp .cell.XXXXXX)
        trap 'rm -f -- "$next"' EXIT
        printf '%s\n' "$selected" > "$next"
        chmod 0644 "$next"
        mv -T -- "$next" cell.json
        echo yes
      fi
    )
    if [[ $changed == yes ]]; then
      exec "$helper" "''${args[@]}"
    fi
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

  # Upstream binaries and the generated cell specification refer to absolute
  # /usr paths. NixOS has no /usr tree, so expose the packaged files there.
  binLinks = map (name: "L+ /usr/bin/${name} - - - - ${droidloom}/usr/bin/${name}") [
    "droidloom-applications"
    "droidloom-audio"
    "droidloom-devices"
    "droidloom-doctor"
    "droidloom-gpu-server"
    "droidloom-supervisor"
    "droidloom-wayland"
    "droidloomctl"
    "droidloomd"
  ];

  toolLinks = map ({ name, path }: "L+ /usr/bin/${name} - - - - ${path}") [
    {
      name = "getent";
      path = "${pkgs.glibc.getent}/bin/getent";
    }
    {
      name = "pkexec";
      path = "${config.security.wrapperDir}/pkexec";
    }
    {
      name = "runuser";
      path = "${pkgs.util-linux}/bin/runuser";
    }
    {
      name = "nsenter";
      path = "${pkgs.util-linux}/bin/nsenter";
    }
    {
      name = "systemctl";
      path = "${pkgs.systemd}/bin/systemctl";
    }
    {
      name = "systemd-run";
      path = "${pkgs.systemd}/bin/systemd-run";
    }
    {
      name = "timeout";
      path = "${pkgs.coreutils}/bin/timeout";
    }
    {
      name = "adb";
      path = "${pkgs.android-tools}/bin/adb";
    }
    {
      name = "cat";
      path = "${pkgs.coreutils}/bin/cat";
    }
  ];
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

    systemd.tmpfiles.rules =
      binLinks
      ++ toolLinks
      ++ [
        "L+ /usr/lib/droidloom - - - - ${droidloom}/usr/lib/droidloom"
        "L+ /usr/share/droidloom - - - - ${droidloom}/usr/share/droidloom"
      ];

    systemd.services.droidloom-setup = {
      description = "Configure Droidloom for ${cfg.user}";
      wantedBy = [ "multi-user.target" ];
      before = [ "droidloomd.service" ];
      after = [
        "local-fs.target"
        "systemd-tmpfiles-setup.service"
      ];
      path = [ pkgs.util-linux ];
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
