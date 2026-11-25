# Droidloom on NixOS

An unofficial flake for [Droidloom](https://github.com/denialwm/droidloom).
It packages upstream release `0.1.0-49` for `x86_64-linux` and `aarch64-linux`.
`nix build .#droidloom` builds the package; running Android also needs the NixOS
and Wayland session setup below.

## Add it to your flake

```nix
inputs.droidloom.url = "github:patrykmil/droidloom-flake";
inputs.droidloom.inputs.nixpkgs.follows = "nixpkgs";
```

For a checkout that hasn't been pushed yet, use `path:/path/to/droidloom-flake`
as the URL.

On the NixOS host, with `inputs` passed to the module:

```nix
{ inputs, ... }:
{
  imports = [ inputs.droidloom.nixosModules.default ];
  services.droidloom = {
    enable = true;
    user = "alice"; # Existing local desktop user
  };
}
```

The module enables the system DMA-BUF heap, which can trigger a kernel rebuild
and require a reboot. Set `services.droidloom.enableDmaHeap = false` if your
kernel already provides `/dev/dma_heap/system`. This is required for the
workaround for Intel GPU `8086:e20b`.

In the desktop user's Home Manager configuration, with `inputs` passed to the module:

```nix
{ inputs, ... }:
{
  imports = [ inputs.droidloom.homeManagerModules.default ];
  programs.droidloom = {
    enable = true;
    enableFcitx5 = true; # Optional; leave off if you already run a Wayland IME
  };
}
```

Apply NixOS and Home Manager, then run `droidloomctl start` from your Wayland
session, without sudo. `droidloomctl applications` lists available Android apps.
When migrating from another Droidloom NixOS/Home Manager configuration, remove
its imports first so both sets of services are not defined at once.

Upstream requires a few `/usr` paths. The module creates missing links to
`/etc/droidloom/compat` and never overwrites an existing file or link in `/usr`.
If setup reports a conflict, inspect it with `readlink /usr/path` and only
remove links you own, such as links left behind by a previous Droidloom
module. Reapply the NixOS configuration afterward.

## Optional Google apps (GApps)

Follow [upstream's add-on build instructions](https://github.com/denialwm/droidloom/blob/572e1c51c5caf75183efe25ad811f98c1268bf56/docs/BUILDING.md#optional-google-apps)
against the **exact** base images in `/usr/lib/droidloom/images`. Android SDK
Build Tools 36 works around an `apksigner` output incompatibility in Droidloom
release 49. An Android 17 `regular lite` archive for the guest's architecture
(including x86_64) can supply all three Google apps directly.

Copy the built add-on's `manifest.json` and `images/` into a real root-owned
directory, for example `/var/lib/droidloom/gapps/49-x86_64`. The files and all
ancestor directories must be root-owned, not group/world-writable, and not
symlinks. Do not use the `/usr/lib/droidloom` symlink or a Nix store path. Keep
the Google APKs, archives, and images out of Git.

```nix
services.droidloom.gapps = {
  enable = true; # Defaults to false
  directory = "/var/lib/droidloom/gapps/49-x86_64";
  # Set dataDirectory only to reuse a pre-existing GApps installation
  # or change the default location.
};
```

Back up first (`droidloomctl backup ~/droidloom-backup.tar.zst`) and stop the
cell before switching system generations. If storage provisioning fails,
the setup service restores the previous storage selection. Enabling GApps selects
`/var/lib/droidloom/users/<uid>/data-gapps` storage by default; disabling it
selects the original `/var/lib/droidloom/users/<uid>/data`. Both directories
are kept. To reuse existing installations at other paths, set
`services.droidloom.dataDirectory` for vanilla and
`services.droidloom.gapps.dataDirectory` for GApps. Do not point both at the
same storage or restore a vanilla backup onto GApps storage.

## License

The packaging code and documentation in this repository are [MIT-licensed](LICENSE).
Droidloom and its dependencies retain their upstream licenses. Google apps are
not distributed by this flake.
