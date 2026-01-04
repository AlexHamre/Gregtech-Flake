{
  description = "GTNH (GregTech: New Horizons) server on NixOS (Java 17–25 pack)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      systems = [ "x86_64-linux"];
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

      nixosModules.gtnh-server = import ./modules/gtnh-server.nix;

      apps = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          pack = self.packages.${system}.gtnhServerPack;
          java = pkgs.jdk21_headless;
        in
        {
          default = {
            type = "app";
            program = toString (pkgs.writeShellScript "run-gtnh" ''
              set -euo pipefail

              ROOT="$(pwd)"
              DATA_DIR="$ROOT/run-gtnh"
              mkdir -p "$DATA_DIR"
              chmod u+rwx "$DATA_DIR" || true
              chmod -R u+rwX "$DATA_DIR" || true
              test -w "$DATA_DIR" || { echo "ERROR: $DATA_DIR is not writable. Remove it or fix perms: rm -rf $DATA_DIR"; exit 1; }

              # Stage pack into writable dir. Keep world(s) and logs across restarts.
              ${pkgs.rsync}/bin/rsync -a --delete \
                --exclude 'world/' \
                --exclude 'world_nether/' \
                --exclude 'world_the_end/' \
                --exclude 'logs/' \
                "${
                  pack
                }"/ "$DATA_DIR"/

              # Ensure directories exist and are writable (fixes log4j + mod config writes)
              mkdir -p "$DATA_DIR/logs" "$DATA_DIR/config"
              chmod -R u+rwX "$DATA_DIR"

              # Ensure shell scripts are executable
              chmod +x "$DATA_DIR"/*.sh 2>/dev/null || true
              chmod +x "$DATA_DIR"/scripts/*.sh 2>/dev/null || true

              # Provide Java to the pack start script
              export JAVA_HOME="${java}"
              export PATH="${java}/bin:${pkgs.coreutils}/bin:${pkgs.gnugrep}/bin:${pkgs.gawk}/bin:${pkgs.findutils}/bin:$PATH"

              # Sanity check
              java -version

              # Create eula.txt on first run
              if [ ! -f "$DATA_DIR/eula.txt" ]; then
                cat > "$DATA_DIR/eula.txt" <<EOF
              eula=false
              EOF
                echo "Created $DATA_DIR/eula.txt with eula=false. Set it to true to run."
                exit 1
              fi

              cd "$DATA_DIR"

              # Ensure the chosen script exists
              if [ ! -f "$DATA_DIR/startserver-java9.sh" ]; then
                echo "ERROR: startserver-java9.sh not found in $DATA_DIR"
                echo "Available scripts:"
                ls -la "$DATA_DIR"/*.sh 2>/dev/null || true
                exit 1
              fi

              exec ${pkgs.bash}/bin/bash "$DATA_DIR/startserver-java9.sh"
            '');
          };
        });
    };
}
