{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.droidloom;
in
{
  options.programs.droidloom = {
    enable = lib.mkEnableOption "the Droidloom Wayland session services";
    enableFcitx5 = lib.mkEnableOption "the Fcitx5 Wayland input method for Android text fields";
  };

  config = lib.mkIf cfg.enable {
    systemd.user.packages = [ (pkgs.callPackage ./package.nix { }) ];

    i18n.inputMethod = lib.mkIf cfg.enableFcitx5 {
      enable = true;
      type = "fcitx5";
      fcitx5.waylandFrontend = true;
    };
  };
}
