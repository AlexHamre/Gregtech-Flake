{
  description = "GTNH (GregTech: New Horizons) server on NixOS (Java 17–25 pack)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      systems = [ "x86_64-linux" ];
      forAllSystems = f: lib.genAttrs systems (system: f system);
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          # Pinned GTNH server pack (Java 17–25)
          gtnhServerPack = pkgs.fetchzip {
            url = "https://downloads.gtnewhorizons.com/ServerPacks/GT_New_Horizons_2.8.4_Server_Java_17-25.zip";
            hash = "sha256-WgTv53dNuH9jZ3L4+STDB/ydRjkWd1iVU7Mzpsp/Pls=";
            stripRoot = false;
          };

          default = self.packages.${system}.gtnhServerPack;
        });

      # NixOS module providing services.gtnh
      nixosModules.gtnh-server = import ./modules/gtnh-server.nix;
    };
}
