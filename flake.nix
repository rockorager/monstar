{
  description = "Monstar — Wayland terminal emulator";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      forAllSystems = nixpkgs.lib.genAttrs nixpkgs.lib.systems.flakeExposed;
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.stdenv.mkDerivation (finalAttrs: {
            pname = "monstar";
            version = "1.0.1";
            src = self;

            zigDeps = pkgs.zig.fetchDeps {
              inherit (finalAttrs) src pname version;
              fetchAll = true;
              hash = "sha256-uAedHwfkI3NrdiRJ90gy4fcg9n/N4xmx3bq15m1h1oU=";
            };

            postConfigure = ''
              ln -s ${finalAttrs.zigDeps} "$ZIG_GLOBAL_CACHE_DIR/p"
            '';

            nativeBuildInputs = [
              pkgs.zig
              pkgs.pkg-config
            ];

            buildInputs = [
              pkgs.wayland
              pkgs.wayland-scanner
              pkgs.wayland-protocols
              pkgs.fontconfig
              pkgs.freetype
              pkgs.harfbuzz
              pkgs.libxkbcommon
            ];
          });
        });

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/monstar";
        };
      });

      devShells = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            nativeBuildInputs = [ pkgs.zig pkgs.pkg-config ];
            buildInputs = [
              pkgs.wayland
              pkgs.wayland-scanner
              pkgs.wayland-protocols
              pkgs.fontconfig
              pkgs.freetype
              pkgs.harfbuzz
              pkgs.libxkbcommon
            ];
          };
        });
    };
}
