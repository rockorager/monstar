{
  description = "Monstar — Wayland terminal emulator";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      linuxSystems = builtins.filter
        (system: (lib.systems.elaborate system).isLinux)
        lib.systems.flakeExposed;
      forAllSystems = lib.genAttrs linuxSystems;
      version = builtins.head
        (builtins.match ''.*[.]version = "([^"]+)".*''
          (builtins.readFile ./build.zig.zon));
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.stdenv.mkDerivation (finalAttrs: {
            pname = "monstar";
            inherit version;
            src = self;

            nativeBuildInputs = [ pkgs.zig_0_17 pkgs.pkg-config pkgs.ncurses ];
            buildInputs = [
              pkgs.wayland
              pkgs.wayland-scanner
              pkgs.wayland-protocols
              pkgs.fontconfig
              pkgs.freetype
              pkgs.harfbuzz
              pkgs.libxkbcommon
              pkgs.vulkan-headers
            ];

            zigDeps = pkgs.zig_0_17.fetchDeps {
              inherit (finalAttrs) src pname version;
              fetchAll = true;
              hash = "sha256-EI3qjCMBJixqrXmZV7t9Aomy+2WWb3sF0J/2K0aPLJw=";
            };

            postConfigure = ''
              ln -s ${finalAttrs.zigDeps} "$ZIG_GLOBAL_CACHE_DIR/p"
            '';

            doInstallCheck = true;
            installCheckPhase = ''
              TERMINFO="$out/share/terminfo" infocmp -x monstar >/dev/null
            '';

            passthru.terminfo = pkgs.stdenv.mkDerivation {
              pname = "monstar-terminfo";
              inherit (finalAttrs) version;
              src = finalAttrs.finalPackage;

              dontUnpack = true;
              dontFixup = true;

              installPhase = ''
                runHook preInstall
                install -d "$out/share/terminfo"
                cp -r "$src/share/terminfo/." "$out/share/terminfo"
                runHook postInstall
              '';

              doInstallCheck = true;
              nativeBuildInputs = [ pkgs.ncurses ];
              installCheckPhase = ''
                TERMINFO="$out/share/terminfo" infocmp -x monstar >/dev/null
              '';
            };
          });
        });

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = lib.getExe' self.packages.${system}.default "monstar";
        };
      });
    };
}
