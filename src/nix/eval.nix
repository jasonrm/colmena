{ rawHive }:
with builtins;
let
  defaultHive = {
    # Will be set in defaultHiveMeta
    meta = {};

    # Like in NixOps, there is a special host named `defaults`
    # containing configurations that will be applied to all
    # hosts.
    defaults = {};
  };

  types = lib.types;

  # Hive-wide options
  metaOptions = { lib, ... }: {
    options = {
      name = lib.mkOption {
        description = ''
          Name of the configuration.
        '';
        type = types.str;
        default = "hive";
      };
      description = lib.mkOption {
        description = ''
          A short description for the configuration.
        '';
        type = types.str;
        default = "A Colmena Hive";
      };
      nixpkgs = lib.mkOption {
        description = ''
          Pinned Nixpkgs. Accepts one of the following:

          - A path to a Nixpkgs checkout
          - The Nixpkgs lambda (e.g., import <nixpkgs>)
          - An initialized Nixpkgs attribute set
        '';
        type = types.unspecified;
        default = <nixpkgs>;
      };
      nodeNixpkgs = lib.mkOption {
        description = ''
          Node-specific Nixpkgs overrides.
        '';
        type = types.attrsOf types.unspecified;
        default = {};
      };
      machinesFile = lib.mkOption {
        description = ''
          Use the machines listed in this file when building this hive configuration.

          If your Colmena host has nix configured to allow for remote builds
          (for nix-daemon, your user being included in trusted-users)
          you can set a machines file that will be passed to the underlying
          nix-store command during derivation realization as a builders option.
          For example, if you support multiple orginizations each with their own
          build machine(s) you can ensure that builds only take place on your
          local machine and/or the machines specified in this file.

          See https://nixos.org/manual/nix/stable/#chap-distributed-builds
          for the machine specification format.
        '';
        default = null;
        apply = value: if value == null then null else toString value;
        type = types.nullOr types.path;
      };
    };
  };

  # Colmena-specific options
  #
  # Largely compatible with NixOps/Morph.
  deploymentOptions = { name, lib, ... }: {
    options = {
      deployment = {
        targetHost = lib.mkOption {
          description = ''
            The target SSH node for deployment.

            By default, the node's attribute name will be used.
            If set to null, only local deployment will be supported.
          '';
          type = types.nullOr types.str;
          default = name;
        };
        targetPort = lib.mkOption {
          description = ''
            The target SSH port for deployment.

            By default, the port is the standard port (22) or taken
            from your ssh_config.
          '';
          type = types.nullOr types.ints.unsigned;
          default = null;
        };
        targetUser = lib.mkOption {
          description = ''
            The user to use to log into the remote node.
          '';
          type = types.str;
          default = "root";
        };
        allowLocalDeployment = lib.mkOption {
          description = ''
            Allow the configuration to be applied locally on the host running
            Colmena.

            For local deployment to work, all of the following must be true:
            - The node must be running NixOS.
            - The node must have deployment.allowLocalDeployment set to true.
            - The node's networking.hostName must match the hostname.

            To apply the configurations locally, run `colmena apply-local`.
            You can also set deployment.targetHost to null if the nost is not
            accessible over SSH (only local deployment will be possible).
          '';
          type = types.bool;
          default = false;
        };
        tags = lib.mkOption {
          description = ''
            A list of tags for the node.

            Can be used to select a group of nodes for deployment.
          '';
          type = types.listOf types.str;
          default = [];
        };
        keys = lib.mkOption {
          description = ''
            A set of secrets to be deployed to the node.

            Secrets are transferred to the node out-of-band and
            never ends up in the Nix store.
          '';
          type = types.attrsOf keyType;
          default = {};
        };
        replaceUnknownProfiles = lib.mkOption {
          description = ''
            Allow a configuration to be applied to a host running a profile we
            have no knowledge of. By setting this option to false, you reduce
            the likelyhood of rolling back changes made via another Colmena user.

            Unknown profiles are usually the result of either:
            - The node had a profile applied, locally or by another Colmena.
            - The host running Colmena garbage-collecting the profile.

            To force profile replacement on all targeted nodes during apply,
            use the flag `--force-replace-unknown-profiles`.
          '';
          type = types.bool;
          default = true;
        };
      };
    };
  };

  keyType = types.submodule {
    options = {
      text = lib.mkOption {
        description = ''
          Content of the key.
          One of `text`, `keyCommand` and `keyFile` must be set.
        '';
        default = null;
        type = types.nullOr types.str;
      };
      keyFile = lib.mkOption {
        description = ''
          Path of the local file to read the key from.
          One of `text`, `keyCommand` and `keyFile` must be set.
        '';
        default = null;
        apply = value: if value == null then null else toString value;
        type = types.nullOr types.path;
      };
      keyCommand = lib.mkOption {
        description = ''
          Command to run to generate the key.
          One of `text`, `keyCommand` and `keyFile` must be set.
        '';
        default = null;
        type = let
          nonEmptyList = types.addCheck (types.listOf types.str) (l: length l > 0);
        in types.nullOr nonEmptyList;
      };
      destDir = lib.mkOption {
        description = ''
          Destination directory on the host.
        '';
        default = "/run/keys";
        type = types.str;
      };
      user = lib.mkOption {
        description = ''
          The group that will own the file.
        '';
        default = "root";
        type = types.str;
      };
      group = lib.mkOption {
        description = ''
          The group that will own the file.
        '';
        default = "root";
        type = types.str;
      };
      permissions = lib.mkOption {
        description = ''
          Permissions to set for the file.
        '';
        default = "0600";
        type = types.str;
      };
    };
  };

  uncheckedUserMeta =
    if rawHive ? meta && rawHive ? network then
      throw "Only one of `network` and `meta` may be specified. `meta` should be used as `network` is for NixOps compatibility."
    else if rawHive ? meta then rawHive.meta
    else if rawHive ? network then rawHive.network
    else {};

  userMeta = (lib.modules.evalModules {
    modules = [ metaOptions uncheckedUserMeta ];
  }).config;

  # The final hive will always have the meta key instead of network.
  hive = let 
    mergedHive = removeAttrs (defaultHive // rawHive) [ "meta" "network" ];
    meta = {
      meta = userMeta;
    };
  in mergedHive // meta;

  mkNixpkgs = configName: pkgConf:
    if typeOf pkgConf == "path" then
      # The referenced file might return an initialized Nixpkgs attribute set directly
      mkNixpkgs configName (import pkgConf)
    else if typeOf pkgConf == "lambda" then
      pkgConf {}
    else if typeOf pkgConf == "set" then
      pkgConf
    else throw ''
      ${configName} must be one of:

      - A path to Nixpkgs (e.g., <nixpkgs>)
      - A Nixpkgs lambda (e.g., import <nixpkgs>)
      - A Nixpkgs attribute set
    '';

  pkgs = let
    # Can't rely on the module system yet
    nixpkgsConf = if uncheckedUserMeta ? nixpkgs then uncheckedUserMeta.nixpkgs else <nixpkgs>;
  in mkNixpkgs "meta.nixpkgs" nixpkgsConf;

  lib = pkgs.lib;
  reservedNames = [ "defaults" "network" "meta" ];

  evalNode = name: config: let
    npkgs =
      if hasAttr name hive.meta.nodeNixpkgs
      then mkNixpkgs "meta.nodeNixpkgs.${name}" hive.meta.nodeNixpkgs.${name}
      else pkgs;
    evalConfig = import (npkgs.path + "/nixos/lib/eval-config.nix");
    assertionModule = { config, ... }: {
      assertions = lib.mapAttrsToList (key: opts: let
        nonNulls = l: filter (x: x != null) l;
      in {
        assertion = length (nonNulls [opts.text opts.keyCommand opts.keyFile]) == 1;
        message =
          let prefix = "${name}.deployment.keys.${key}";
          in "Exactly one of `${prefix}.text`, `${prefix}.keyCommand` and `${prefix}.keyFile` must be set.";
        }) config.deployment.keys;
    };

    # Here we need to merge the configurations in meta.nixpkgs
    # and in machine config.
    nixpkgsModule = { config, lib, ... }: {
      nixpkgs.overlays = lib.mkBefore npkgs.overlays;
      nixpkgs.config = lib.mkOptionDefault npkgs.config;

      # The merging of nixpkgs.config seems to be broken.
      # Let's warn the user if not all config attributes set in
      # meta.nixpkgs are overridden.
      warnings = let
        metaKeys = attrNames npkgs.config;
        nodeKeys = [ "doCheckByDefault" "warnings" ] ++ (attrNames config.nixpkgs.config);
        remainingKeys = filter (k: ! elem k nodeKeys) metaKeys;
      in
        lib.optional (length remainingKeys != 0)
        "The following Nixpkgs configuration keys set in meta.nixpkgs will be ignored: ${toString remainingKeys}";
    };
  in evalConfig {
    modules = [
      assertionModule
      nixpkgsModule
      deploymentOptions
      hive.defaults
      config
    ] ++ (import (npkgs.path + "/nixos/modules/module-list.nix"));
    specialArgs = {
      inherit name nodes;
      modulesPath = npkgs.path + "/nixos/modules";
    };
  };

  nodeNames = filter (name: ! elem name reservedNames) (attrNames hive);

  # Exported attributes
  #
  # Functions are intended to be called with `nix-instantiate --eval --json`

  nodes = listToAttrs (map (name: {
    inherit name;
    value = evalNode name hive.${name};
  }) nodeNames);

  deploymentConfigJson = toJSON (lib.attrsets.mapAttrs (name: eval: eval.config.deployment) nodes);

  toplevel = lib.attrsets.mapAttrs (name: eval: eval.config.system.build.toplevel) nodes;

  buildAll = buildSelected {
    names = nodeNames;
  };
  buildSelected = { names ? null }: let
    # Change in the order of the names should not cause a derivation to be created
    selected = lib.attrsets.filterAttrs (name: _: elem name names) toplevel;
  in derivation rec {
    name = "colmena-${hive.meta.name}";
    system = currentSystem;
    json = toJSON (lib.attrsets.mapAttrs (k: v: toString v) selected);
    builder = pkgs.writeScript "${name}.sh" ''
      #!/bin/sh
      echo "$json" > $out
    '';
  };

  introspect = function: function {
    inherit pkgs lib nodes;
  };
in {
  inherit nodes deploymentConfigJson toplevel buildAll buildSelected introspect;
  meta = hive.meta;
}
