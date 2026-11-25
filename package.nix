{
  lib,
  stdenv,
  fetchurl,
  libgbm,
  libxkbcommon,
  patchelf,
  pipewire,
  zstd,
}:
let
  version = "0.1.0";
  release = 49;

  arch =
    {
      x86_64-linux = "x86_64";
      aarch64-linux = "aarch64";
    }
    .${stdenv.hostPlatform.system}
      or (throw "droidloom: unsupported platform ${stdenv.hostPlatform.system}");

  # Hashes of the pacman tarballs published on the "packages" release.
  hashes = {
    base = {
      x86_64 = "sha256-qjE9By+JNcbFZzKnRAote6uOt5dUDjDgdBHKkblfcm4=";
      aarch64 = "sha256-QHEqbrG8xFHIxL3SylspUfhF0EHEdGpLsqB7Mlm0lHM=";
    };
    runtime = {
      x86_64 = "sha256-pQow/GZPEoRVbRztUaOGRBqytMIXeuWBKFoOsAKkaEw=";
      aarch64 = "sha256-blzxjHwZbz/6WnnKk44Mr4MVVIYQ8hu220ra4ONdvCg=";
    };
    image = {
      x86_64 = "sha256-ptzEnodycmKmskm9etDtFA0RSSULmD81HRUeW9r69p8=";
      aarch64 = "sha256-glfv+tETUD7F0O02ngstbWHNl283+TzluaIG+IOpYGI=";
    };
  };

  hostLibs = [
    libgbm
    libxkbcommon
    pipewire
  ];
  runtimePath = lib.makeLibraryPath (hostLibs ++ [ stdenv.cc.cc.lib ]);

  fetchComponent =
    component:
    let
      name = "droidloom-${component}-${version}-${toString release}-${arch}.pkg.tar.zst";
    in
    fetchurl {
      inherit name;
      url = "https://github.com/denialwm/droidloom/releases/download/packages/${name}";
      hash = hashes.${component}.${arch};
    };
in
stdenv.mkDerivation {
  pname = "droidloom";
  version = "${version}-${toString release}";

  srcs = map fetchComponent [
    "base"
    "runtime"
    "image"
  ];

  nativeBuildInputs = [
    patchelf
    zstd
  ];

  buildInputs = hostLibs;

  unpackPhase = ''
    runHook preUnpack
    mkdir -p usr
    for src in $srcs; do
      zstd -d -c "$src" | tar -xf - \
        --exclude=.BUILDINFO --exclude=.MTREE --exclude=.PKGINFO
    done
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    mv usr $out/usr
    mkdir -p $out/bin
    for f in $out/usr/bin/*; do
      ln -s ../usr/bin/$(basename "$f") "$out/bin/$(basename "$f")"
    done

    # Home Manager installs user units from share/systemd/user.
    mkdir -p $out/share/systemd/user
    cp -a $out/usr/lib/systemd/user/. $out/share/systemd/user/
    cp -a $out/usr/share/polkit-1 $out/share/

    # Only the host-side binaries use the system dynamic loader. The Android
    # ELFs under usr/lib/droidloom/current use Bionic and must stay untouched.
    for f in $out/usr/bin/* $out/usr/lib/droidloom/droidloom-package-helper; do
      patchelf \
        --set-interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" \
        --set-rpath "${runtimePath}" \
        "$f"
    done
    runHook postInstall
  '';

  meta = {
    description = "Android apps in Wayland windows, on the host Linux kernel";
    homepage = "https://github.com/denialwm/droidloom";
    license = lib.licenses.gpl3Plus;
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    mainProgram = "droidloomctl";
  };
}
