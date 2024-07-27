with import <nixpkgs> {};

let
  unstable = import
    (builtins.fetchTarball "https://github.com/NixOS/nixpkgs/archive/8001cc402f61b8fd6516913a57ec94382455f5e5.tar.gz")
    # reuse the current configuration
    { config = config; };
in
pkgs.mkShell {
  nativeBuildInputs = with pkgs; [
    unstable.zls
    unstable.zig_0_13
    gdb
    valgrind
    python3
    wabt
    expat
    nodePackages.typescript-language-server
    vscode-langservers-extracted
    nodePackages.prettier
    nodePackages.jshint
    linuxPackages_latest.perf
    glfw
    wayland
    pkg-config
  ];

  LD_LIBRARY_PATH = "${wayland}/lib";
}

