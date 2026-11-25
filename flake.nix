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
        in
        {
          storage-selection =
            pkgs.runCommand "droidloom-storage-selection" { nativeBuildInputs = [ pkgs.jq ]; }
              ''
                set -o pipefail
                select_storage() {
                  jq --arg vanilla /vanilla --arg google /google --arg addon "$1" \
                    -f ${./select-storage.jq}
                }
                spec='{"host_uid":1000,"data_dir":"/vanilla","graphics_backend":"drm"}'
                enabled=$(printf '%s\n' "$spec" | select_storage /addon)
                jq -e '.data_dir == "/google" and .gapps_dir == "/addon"' <<< "$enabled"
                select_storage "" <<< "$enabled" | jq -e --argjson spec "$spec" '. == $spec'
                touch "$out"
              '';
        }
      );
    };
}
