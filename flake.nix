{
  description = "Droidloom for NixOS and Home Manager";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";

  outputs =
    { nixpkgs, ... }:
    let
      forSystems = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
      ];
    in
    {
      packages = forSystems (
        system:
        let
          droidloom = nixpkgs.legacyPackages.${system}.callPackage ./package.nix { };
        in
        {
          inherit droidloom;
          default = droidloom;
        }
      );

      nixosModules.default = import ./nixos.nix;
      homeManagerModules.default = import ./home-manager.nix;

      checks = forSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          cfg =
            (nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [
                ./nixos.nix
                {
                  users.users.alice.isNormalUser = true;
                  services.droidloom = {
                    enable = true;
                    user = "alice";
                  };
                }
              ];
            }).config;
          catRules = builtins.filter (nixpkgs.lib.hasInfix " /usr/bin/cat ") cfg.systemd.tmpfiles.rules;
        in
        {
          storage-selection =
            pkgs.runCommand "droidloom-storage-selection"
              {
                nativeBuildInputs = [
                  pkgs.jq
                  pkgs.util-linux
                ];
              }
              ''
                switch_storage() {
                  bash ${./switch-storage.sh} ${./select-storage.jq} /vanilla /google "$@"
                }
                spec='{"host_uid":1000,"data_dir":"/vanilla","graphics_backend":"drm"}'
                printf '%s\n' "$spec" > cell.json
                cat > failing-helper <<'EOF'
                jq -e '.data_dir == "/google" and .gapps_dir == "/addon"' cell.json || exit 1
                exit 42
                EOF
                status=0
                switch_storage /addon flock -x setup.lock bash failing-helper || status=$?
                test "$status" = 42
                jq -e --argjson spec "$spec" '. == $spec' cell.json

                switch_storage /addon true
                google=$(jq -ce 'select(.data_dir == "/google" and .gapps_dir == "/addon")' cell.json)
                status=0
                switch_storage "" false || status=$?
                test "$status" = 1
                jq -e --argjson google "$google" '. == $google' cell.json

                switch_storage "" true
                jq -e --argjson spec "$spec" '. == $spec' cell.json
                touch "$out"
              '';

          compat-links = pkgs.runCommand "droidloom-compat-links" { nativeBuildInputs = [ pkgs.systemd ]; } ''
            mkdir -p root/usr/bin
            test ${toString (builtins.length catRules)} = 1
            printf '%s\n' ${nixpkgs.lib.escapeShellArgs catRules} > links.conf
            printf 'existing\n' > root/usr/bin/cat
            systemd-tmpfiles --root="$PWD/root" --create "$PWD/links.conf"
            test ! -L root/usr/bin/cat
            test "$(cat root/usr/bin/cat)" = existing
            rm root/usr/bin/cat
            ln -s /other/cat root/usr/bin/cat
            systemd-tmpfiles --root="$PWD/root" --create "$PWD/links.conf"
            test "$(readlink root/usr/bin/cat)" = /other/cat
            rm root/usr/bin/cat
            systemd-tmpfiles --root="$PWD/root" --create "$PWD/links.conf"
            test "$(readlink root/usr/bin/cat)" = /etc/droidloom/compat/bin/cat
            touch "$out"
          '';
        }
      );
    };
}
