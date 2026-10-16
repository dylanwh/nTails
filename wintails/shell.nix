# Cross-builds wintails.exe, ntailsd.exe, and ntails.msi from macOS or Linux:
#   nix-shell
#   meson setup build --cross-file cross/mingw64.ini
#   meson compile -C build msi
let
  nixpkgs = fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/eaad089433ca2bb662274377d33df3d0e51ef28b.tar.gz";
    sha256 = "1sgjzd65nv5m8bk5i32jsxjns3z3gncbdx5blqkywzyrkilv188z";
  };
  pkgs = import nixpkgs { };
  cross = pkgs.pkgsCross.mingwW64;
in
cross.mkShell {
  nativeBuildInputs = [
    pkgs.meson
    pkgs.ninja
    pkgs.pkg-config
    pkgs.go_1_27
    pkgs.msitools
  ];
  # The qrencode subproject links -lpthread; the gcc here has no static one
  # of its own.
  buildInputs = [ cross.windows.pthreads ];
}
