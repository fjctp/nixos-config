{ lib, pkgs, config, ... }:
{
  # Define options for "services.podman-compose.<name>"
  options.services.podman-compose = lib.mkOption {
    description = lib.mdDoc ''
      Run containers as defined in a YAML file using podman-compose.
    '';
    type = lib.types.attrsOf (lib.types.submodule ({ config, name, ... }: {
      options = 
        let 
          forwardPortType = lib.types.submodule {
            options = {
              protocol = lib.mkOption {
                type = lib.types.str;
                default = "tcp";
                description = lib.mdDoc "The protocol specifier for port forwarding between host and container";
              };
              hostPort = lib.mkOption {
                type = lib.types.port;
                description = lib.mdDoc "Source port of the external interface on host";
              };
              containerPort = lib.mkOption {
                type = lib.types.port;
                description = lib.mdDoc "Target port of container";
              };
            };
          };
        in
        {
        ymlDir = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = lib.mdDoc ''
            Location of the YAML file.
          '';
          example = "/var/lib/syncthing";
        };
        ymlFile = lib.mkOption {
          type = lib.types.str;
          default = "docker-compose.yml";
          description = lib.mdDoc ''
            Name of YAML file to use.
          '';
          example = "docker-compose.yml";
        };
        network = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = lib.mdDoc ''
            Connnet a pod to a network.
          '';
          example = "/var/lib/syncthing";
        };
        openPorts = lib.mkOption {
          type = lib.types.bool;
          default = true;
          example = false;
          description = lib.mdDoc ''
             Whether to open the host ports in the firewall.
          '';
        };
        forwardPorts = lib.mkOption {
          type = lib.types.listOf forwardPortType;
          default = [];
          example = [ { protocol = "tcp"; hostPort = 8080; containerPort = 80; } ];
          description = lib.mdDoc ''
            List of forwarded ports from host to container. Each forwarded port
            is specified by protocol, hostPort and containerPort. By default,
            protocol is tcp and hostPort and containerPort are assumed to be
            the same if containerPort is not explicitly given.
          '';
        };
      };
    }));
    default = { };
    example = {
      syncthing = {
        ymlFile = "docker-compose.yml";
        ymlDir = "/var/lib/syncthing";
      };
    };
  };

  # Define nixos configurations based on options above.
  config = let
    cfg = config.services.podman-compose;
  in
  {
    # Enable depenencies
    virtualisation.podman.enable = true;
    environment.systemPackages = with pkgs; [ 
      podman-compose
      jq # Command line tool to read JSON
      yj # Convert YAML to JSON
    ];

    # Open ports in firewall
    networking.firewall = 
      let
        # Get all pod config.
        pod_cfg = lib.collect (x: x ? forwardPorts) cfg;

        # Keep pod config if openPort is true and there is at least a forward port.
        pod_cfg_filtered = lib.filter (
          c: c.openPorts && (lib.length c.forwardPorts > 0)) pod_cfg;

        # Extract forwardPorts settings from pod config
        all_forwardPorts = lib.flatten (
          map (c: c.forwardPorts) pod_cfg_filtered
        );

        # Get all host ports for the given protocol
        get_hostPorts = protocol: map (c: c.hostPort) (
          lib.filter (c: c.protocol == protocol) all_forwardPorts
        );
      in
      {
        allowedTCPPorts = get_hostPorts "tcp";
        allowedUDPPorts = get_hostPorts "udp";
      };

    # Define a user systemd service for each name and value pair
    # under "services.podman-compose"
    systemd.user.services =
      lib.mapAttrs'
      (name: pod:
        let
          mkPortStr = p: "--publish ${toString p.hostPort}:${toString p.containerPort}/${p.protocol}";
          compose_exe = "${pkgs.podman-compose}/bin/podman-compose";
          pod_opt = [
            "--infra=true"
            "--share='ipc,net,uts'"
            "--share-parent=true"
            "--infra-name='${name}_infra'"
            (lib.optionalString (pod.network != null) "--network ${pod.network}")
            (lib.optionalString (lib.length pod.forwardPorts > 0) "${lib.concatStringsSep " " (map mkPortStr pod.forwardPorts)}")
          ];
          compose_opt = ''
            --file ${pod.ymlFile} \
            --in-pod=1 \
            --project-name ${name} \
            --pod-args="${lib.concatStringsSep " " pod_opt}" \
          '';
          ymlDir = "${pod.ymlDir}"; # Location of docker-compose.yml
        in
        lib.nameValuePair "pod-${name}" ({
          enable = true;
          path = [ 
            "/run/wrappers" # For rootless podman, need "newuidmap"
            "${pkgs.podman}" # Need "podman"
          ];
          description = "Rootless pod for ${name}";
          serviceConfig = {
            Type = "forking";
            Restart = "on-failure";
            WorkingDirectory = "${ymlDir}";
            RestartSec = 30; # Wait 30 sec before restart
            TimeoutStopSec = 20;
            ExecStartPre = "${compose_exe} pull";
            ExecStart = "${compose_exe} ${compose_opt} up -d";
            ExecStop = "${compose_exe} ${compose_opt} down";
          };

          after = [ "default.service" ];
          wantedBy = [ "default.target" ];
        })
      )
      cfg;
  };
}
