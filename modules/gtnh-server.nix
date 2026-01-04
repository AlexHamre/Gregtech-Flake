{ config, lib, pkgs, ... }:
let
  cfg = config.services.gtnh;

  # Convert an attrset to server.properties format (Minecraft expects booleans as "true"/"false")
  mkPropertiesFile = props:
    let
      render = v:
        if lib.isBool v then (if v then "true" else "false")
        else toString v;
    in
    pkgs.writeText "server.properties" (
      lib.concatStringsSep "\n"
        (lib.mapAttrsToList (k: v: "${k}=${render v}") props)
      + "\n"
    );

  serverPropertiesFile = mkPropertiesFile cfg.serverProperties;

  # A small wrapper that:
  # - syncs pack -> dataDir (excluding world/)
  # - ensures scripts are executable
  # - ensures logs/config dirs exist and are writable by the service user
  # - writes eula.txt and server.properties declaratively
  # - chooses a start script (explicit or autodetect)
  startWrapper = pkgs.writeShellScript "gtnh-start" ''
    set -euo pipefail

    DATA_DIR="${cfg.dataDir}"
    PACK_DIR="${cfg.serverPack}"

    mkdir -p "$DATA_DIR"
    cd "$DATA_DIR"

    # Sync server pack into writable data dir; keep persistent data
    ${pkgs.rsync}/bin/rsync -a --delete \
      --exclude 'world/' \
      --exclude 'world_nether/' \
      --exclude 'world_the_end/' \
      --exclude 'logs/' \
      --exclude 'eula.txt' \
      --exclude 'server.properties' \
      "$PACK_DIR"/ "$DATA_DIR"/

    # Ensure runtime directories exist (log4j + mods write here)
    mkdir -p "$DATA_DIR/logs" "$DATA_DIR/config"
    chmod -R u+rwX "$DATA_DIR" 2>/dev/null || true

    # Ensure shell scripts are executable (some zips preserve perms, some don't)
    chmod +x "$DATA_DIR"/*.sh 2>/dev/null || true
    chmod +x "$DATA_DIR"/scripts/*.sh 2>/dev/null || true

    # Write EULA and server.properties declaratively
    cat > "$DATA_DIR/eula.txt" <<EOF
eula=${if cfg.eula then "true" else "false"}
EOF

    install -m 0644 ${serverPropertiesFile} "$DATA_DIR/server.properties"

    # Select start script
    if [ -n "${cfg.startScript}" ]; then
      exec ${pkgs.bash}/bin/bash "$DATA_DIR/${cfg.startScript}"
    fi

    # Autodetect common GTNH server scripts
    for s in startserver.sh startserver-java*.sh startserver-*.sh; do
      if [ -f "$DATA_DIR/$s" ]; then
        exec ${pkgs.bash}/bin/bash "$DATA_DIR/$s"
      fi
    done

    echo "ERROR: Could not find a start script in $DATA_DIR"
    echo "Set services.gtnh.startScript to the correct script name."
    ls -la "$DATA_DIR" || true
    exit 1
  '';
in
{
  options.services.gtnh = {
    enable = lib.mkEnableOption "GTNH (GregTech: New Horizons) server";

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/gtnh";
      description = "Writable data directory for the GTNH server (world, logs, configs).";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open TCP port for the server.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 25565;
      description = "Minecraft server port.";
    };

    eula = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to accept the Minecraft EULA.";
    };

    serverPack = lib.mkOption {
      type = lib.types.path;
      description = "Path to the extracted GTNH server pack (a derivation from fetchzip).";
    };

    javaPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.jdk21_headless;
      description = "Java runtime to use (Java 17–25 pack recommended on a modern JDK such as 21).";
    };

    startScript = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "startserver-java9.sh";
      description = ''
        Name of the start script inside dataDir. If empty, the service will try to autodetect
        startserver*.sh.
      '';
    };

    jvmArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Extra JVM args (if you prefer to wrap Java yourself; typically GTNH scripts set these).";
    };

    serverProperties = lib.mkOption {
      type = lib.types.attrsOf (lib.types.oneOf [ lib.types.str lib.types.int lib.types.bool ]);
      default = {
        "server-port" = 25565;
        "max-players" = 10;
        "online-mode" = true;
        "white-list" = false;
        "motd" = "GTNH Server";
      };
      description = "Declarative server.properties key/values.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.gtnh = {};
    users.users.gtnh = {
      isSystemUser = true;
      group = "gtnh";
      home = cfg.dataDir;
      createHome = true;
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 gtnh gtnh - -"
      "d ${cfg.dataDir}/logs 0750 gtnh gtnh - -"
      "d ${cfg.dataDir}/config 0750 gtnh gtnh - -"
    ];

    # Robustly fix ownership at activation time (handles pre-existing root-owned files)
    system.activationScripts.gtnh-permissions.text = ''
      ${pkgs.coreutils}/bin/mkdir -p ${cfg.dataDir} ${cfg.dataDir}/logs ${cfg.dataDir}/config
      ${pkgs.coreutils}/bin/chown -R gtnh:gtnh ${cfg.dataDir}
      ${pkgs.coreutils}/bin/chmod 0750 ${cfg.dataDir}
    '';

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];

    systemd.services.gtnh = {
      description = "GTNH (GregTech: New Horizons) Minecraft Server";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "simple";
        User = "gtnh";
        Group = "gtnh";
        WorkingDirectory = cfg.dataDir;

        # Run wrapper (stages files + writes config + starts pack script)
        ExecStart = "${startWrapper}";

        Restart = "on-failure";
        RestartSec = 5;

        # Modded servers can open lots of files
        LimitNOFILE = 1048576;
      };

      path = [
        cfg.javaPackage
        pkgs.bash
        pkgs.coreutils
        pkgs.rsync
        pkgs.findutils
        pkgs.gnugrep
        pkgs.gawk
      ];

      environment = {
        JAVA_HOME = "${cfg.javaPackage}";
      };
    };
  };
}
