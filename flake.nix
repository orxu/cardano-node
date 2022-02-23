{
  description = "Cardano Node";

  inputs = {
    # IMPORTANT: report any change to nixpkgs channel in nix/default.nix:
    nixpkgs.follows = "haskellNix/nixpkgs-2105";
    hostNixpkgs.follows = "nixpkgs";
    haskellNix = {
      url = "github:input-output-hk/haskell.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    utils.url = "github:numtide/flake-utils";
    iohkNix = {
      url = "github:input-output-hk/iohk-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-compat = {
      url = "github:input-output-hk/flake-compat/fixes";
      flake = false;
    };
    membench = {
      url = "github:input-output-hk/cardano-memory-benchmark";
      inputs.cardano-node-measured.follows = "/";
      inputs.cardano-node-process.follows = "/";
      inputs.cardano-node-snapshot.url = "github:input-output-hk/cardano-node/7f00e3ea5a61609e19eeeee4af35241571efdf5c";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Custom user config (default: empty), eg.:
    # { outputs = {...}: {
    #   # Cutomize listeming port of node scripts:
    #   nixosModules.cardano-node = {
    #     services.cardano-node.port = 3002;
    #   };
    # };
    customConfig.url = "github:input-output-hk/empty-flake";
    plutus-example = {
      url = "github:input-output-hk/cardano-node/1.33.0";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, hostNixpkgs, utils, haskellNix, iohkNix, membench, plutus-example, ... }@input:
    let
      inherit (nixpkgs) lib;
      inherit (lib) head systems mapAttrs recursiveUpdate mkDefault
        getAttrs optionalAttrs nameValuePair attrNames;
      inherit (utils.lib) eachSystem mkApp flattenTree;
      inherit (iohkNix.lib) prefixNamesWith;
      removeRecurse = lib.filterAttrsRecursive (n: _: n != "recurseForDerivations");
      flatten = attrs: lib.foldl' (acc: a: if (lib.isAttrs a) then acc // (removeAttrs a [ "recurseForDerivations" ]) else acc) { } (lib.attrValues attrs);

      supportedSystems = import ./nix/supported-systems.nix;
      defaultSystem = head supportedSystems;
      customConfig = recursiveUpdate
        (import ./nix/custom-config.nix customConfig)
        input.customConfig;

      overlays = [
        haskellNix.overlay
        iohkNix.overlays.haskell-nix-extra
        iohkNix.overlays.crypto
        iohkNix.overlays.cardano-lib
        iohkNix.overlays.utils
        (final: prev: {
          inherit customConfig;
          gitrev = final.customConfig.gitrev or self.rev or "0000000000000000000000000000000000000000";
          commonLib = lib
            // iohkNix.lib
            // final.cardanoLib
            // import ./nix/svclib.nix { inherit (final) pkgs; };
        })
        (import ./nix/pkgs.nix)
        self.overlay
      ];

      projectPackagesExes = import ./nix/project-packages-exes.nix;

      mkPackages = project:
        let
          inherit (project.pkgs.stdenv) hostPlatform;
          inherit (project.pkgs.haskell-nix) haskellLib;
          profiledProject = project.appendModule {
            modules = [{
              enableLibraryProfiling = true;
              packages.cardano-node.components.exes.cardano-node.enableProfiling = true;
              packages.tx-generator.components.exes.tx-generator.enableProfiling = true;
              packages.locli.components.exes.locli.enableProfiling = true;
            }];
          };
          assertedProject = project.appendModule {
            modules = [{
              packages = lib.genAttrs [
                "ouroboros-consensus"
                "ouroboros-consensus-cardano"
                "ouroboros-consensus-byron"
                "ouroboros-consensus-shelley"
                "ouroboros-network"
                "network-mux"
              ]
                (name: { flags.asserts = true; });
            }];
          };
          eventloggedProject = project.appendModule
            {
              modules = [{
                packages = lib.genAttrs [ "cardano-node" ]
                  (name: { configureFlags = [ "--ghc-option=-eventlog" ]; });
              }];
            };
          inherit ((import plutus-example {
            inherit (project.pkgs) system;
            gitrev = plutus-example.rev;
          }).haskellPackages.plutus-example.components.exes) plutus-example;
          hsPkgsWithPassthru = lib.mapAttrsRecursiveCond (v: !(lib.isDerivation v))
            (path: value:
              if (lib.isAttrs value) then
                lib.recursiveUpdate value
                  {
                    passthru = {
                      profiled = lib.getAttrFromPath path profiledProject.hsPkgs;
                      asserted = lib.getAttrFromPath path assertedProject.hsPkgs;
                      eventlogged = lib.getAttrFromPath path eventloggedProject.hsPkgs;
                    };
                  } else value)
            project.hsPkgs;
          projectPackages = lib.mapAttrs (n: _: hsPkgsWithPassthru.${n}) projectPackagesExes;
        in
        {
          inherit projectPackages profiledProject assertedProject eventloggedProject;
          projectExes = flatten (haskellLib.collectComponents' "exes" projectPackages) // (with hsPkgsWithPassthru; {
            inherit (ouroboros-consensus-byron.components.exes) db-converter;
            inherit (ouroboros-consensus-cardano.components.exes) db-analyser;
            inherit (bech32.components.exes) bech32;
          } // lib.optionalAttrs hostPlatform.isUnix {
            inherit (network-mux.components.exes) cardano-ping;
          });
        };

      mkCardanoNodePackages = project: (mkPackages project).projectExes // {
        inherit (project.pkgs) cardanoLib;
      };

      flake = eachSystem supportedSystems (system:
        let
          pkgs = import nixpkgs {
            inherit system overlays;
            inherit (haskellNix) config;
          };
          inherit (pkgs.haskell-nix) haskellLib;
          inherit (haskellLib) collectChecks' collectComponents';
          inherit (pkgs.commonLib) eachEnv environments mkSupervisordCluster;
          inherit (project.pkgs.stdenv) hostPlatform;

          project = (import ./nix/haskell.nix {
            inherit (pkgs) haskell-nix gitrev;
            inherit projectPackagesExes;
          }).appendModule customConfig.haskellNix // {
            profiled = profiledProject;
            asserted = assertedProject;
            eventlogged = eventloggedProject;
          };

          inherit (mkPackages project) projectPackages projectExes profiledProject assertedProject eventloggedProject;

          shell = import ./shell.nix { inherit pkgs customConfig; };
          devShells = {
            inherit (shell) devops;
            cluster = shell;
            profiled = project.profiled.shell;
          };

          devShell = shell.dev;

          # NixOS tests run a node and submit-api and validate it listens
          nixosTests = import ./nix/nixos/tests {
            inherit pkgs;
          };

          checks = flattenTree (collectChecks' projectPackages) //
            # Linux only checks:
            (optionalAttrs hostPlatform.isLinux (
              prefixNamesWith "nixosTests/" (mapAttrs (_: v: v.${system} or v) nixosTests)
            ))
            # checks run on default system only;
            // (optionalAttrs (system == defaultSystem) {
            hlint = pkgs.callPackage pkgs.hlintCheck {
              inherit (project.args) src;
            };
          });

          exes = projectExes // {
            inherit (pkgs) cabalProjectRegenerate checkCabalProject;
            "dockerImages/push" = import ./.buildkite/docker-build-push.nix {
              hostPkgs = import hostNixpkgs { inherit system; };
              inherit (pkgs) dockerImage submitApiDockerImage;
            };
            "dockerImage/node/load" = pkgs.writeShellScript "load-docker-image" ''
              docker load -i ${pkgs.dockerImage} $@
            '';
            "dockerImage/submit-api/load" = pkgs.writeShellScript "load-submit-docker-image" ''
              docker load -i ${pkgs.submitApiDockerImage} $@
            '';
          } // flattenTree (pkgs.scripts // {
            # `tests` are the test suites which have been built.
            tests = collectComponents' "tests" projectPackages;
            # `benchmarks` (only built, not run).
            benchmarks = collectComponents' "benchmarks" projectPackages;
          });

          packages = exes
            # Linux only packages:
            // optionalAttrs (system == "x86_64-linux") rec {
            "dockerImage/node" = pkgs.dockerImage;
            "dockerImage/submit-api" = pkgs.submitApiDockerImage;
            membenches = membench.outputs.packages.x86_64-linux.batch-report;
            snapshot = membench.outputs.packages.x86_64-linux.snapshot;
            workbench-smoke-test     = pkgs.clusterNix.profile-run-supervisord { profileName = "smoke-alzo"; };
            workbench-smoke-analysis = pkgs.clusterNix.workbench.run-analysis
              { inherit pkgs; run = workbench-smoke-test; trace = true; };
          }
            # Add checks to be able to build them individually
            // (prefixNamesWith "checks/" checks);

          apps = lib.mapAttrs (n: p: { type = "app"; program = p.exePath or (if (p.executable or false) then "${p}" else "${p}/bin/${p.name or n}"); }) exes;

        in
        {

          inherit environments packages checks apps project;

          legacyPackages = pkgs;

          # Built by `nix build .`
          defaultPackage = packages.cardano-node;

          # Run by `nix run .`
          defaultApp = apps.cardano-node;

          # This is used by `nix develop .` to open a devShell
          inherit devShell devShells;

          systemHydraJobs = optionalAttrs (system == "x86_64-linux")
            {
              linux = {
                native = packages // {
                  shells = devShells // {
                    default = devShell;
                  };
                  internal = {
                    roots.project = project.roots;
                    plan-nix.project = project.plan-nix;
                  };
                  profiled = lib.genAttrs [ "cardano-node" "tx-generator" "locli" ] (n:
                    packages.${n}.passthru.profiled
                  );
                  asserted = lib.genAttrs [ "cardano-node" ] (n:
                    packages.${n}.passthru.asserted
                  );
                };
                musl =
                  let
                    muslProject = project.projectCross.musl64;
                    inherit (mkPackages muslProject) projectPackages projectExes;
                  in
                  projectExes // {
                    cardano-node-linux = import ./nix/binary-release.nix {
                      inherit pkgs;
                      inherit (exes.cardano-node.identifier) version;
                      platform = "linux";
                      exes = lib.collect lib.isDerivation projectExes;
                    };
                    internal.roots.project = muslProject.roots;
                  };
                windows =
                  let
                    windowsProject = project.projectCross.mingwW64;
                    inherit (mkPackages windowsProject) projectPackages projectExes;
                  in
                  projectExes
                    // (removeRecurse {
                    checks = collectChecks' projectPackages;
                    tests = collectComponents' "tests" projectPackages;
                    benchmarks = collectComponents' "benchmarks" projectPackages;
                    cardano-node-win64 = import ./nix/binary-release.nix {
                      inherit pkgs;
                      inherit (exes.cardano-node.identifier) version;
                      platform = "win64";
                      exes = lib.collect lib.isDerivation projectExes;
                    };
                    internal.roots.project = windowsProject.roots;
                  });
              };
            } // optionalAttrs (system == "x86_64-darwin") {
            macos = lib.filterAttrs
              (n: _:
                # only build docker images once on linux:
                !(lib.hasPrefix "dockerImage" n))
              packages // {
              cardano-node-macos = import ./nix/binary-release.nix {
                inherit pkgs;
                inherit (exes.cardano-node.identifier) version;
                platform = "macos";
                exes = lib.collect lib.isDerivation projectExes;
              };
              shells = removeAttrs devShells [ "profiled" ] // {
                default = devShell;
              };
              internal = {
                roots.project = project.roots;
                plan-nix.project = project.plan-nix;
              };
            };
          };
        }
      );

    in
    builtins.removeAttrs flake [ "systemHydraJobs" ] // {
      hydraJobs =
        let
          jobs = lib.foldl' lib.mergeAttrs { } (lib.attrValues flake.systemHydraJobs);
          nonRequiredPaths = map lib.hasPrefix [ ];
        in
        jobs // (with self.legacyPackages.${defaultSystem}; rec {
          cardano-deployment = cardanoLib.mkConfigHtml { inherit (cardanoLib.environments) mainnet testnet; };
          build-version = writeText "version.json" (builtins.toJSON {
            inherit (self) lastModified lastModifiedDate narHash outPath shortRev rev;
          });
          required = releaseTools.aggregate {
            name = "github-required";
            meta.description = "All jobs required to pass CI";
            constituents = lib.collect lib.isDerivation
              (lib.mapAttrsRecursiveCond (v: !(lib.isDerivation v))
                (path: value:
                  let stringPath = lib.concatStringsSep "." path; in if lib.isAttrs value && (lib.any (p: p stringPath) nonRequiredPaths) then { } else value)
                jobs) ++ [
              cardano-deployment
              build-version
            ];
          };
        });
      overlay = final: prev: {
        cardanoNodeProject = flake.project.${final.system};
        cardanoNodePackages = mkCardanoNodePackages final.cardanoNodeProject;
        inherit (final.cardanoNodePackages) cardano-node cardano-cli cardano-submit-api bech32;
      };
      nixosModules = {
        cardano-node = { pkgs, lib, ... }: {
          imports = [ ./nix/nixos/cardano-node-service.nix ];
          services.cardano-node.cardanoNodePackages = lib.mkDefault (mkCardanoNodePackages flake.project.${pkgs.system});
        };
        cardano-submit-api = { pkgs, lib, ... }: {
          imports = [ ./nix/nixos/cardano-submit-api-service.nix ];
          services.cardano-submit-api.cardanoNodePackages = lib.mkDefault (mkCardanoNodePackages flake.project.${pkgs.system});
        };
      };
    };
}
