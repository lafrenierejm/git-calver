{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    crane = {
      url = "github:ipetkov/crane";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
    };
    advisory-db = {
      url = "github:rustsec/advisory-db";
      flake = false;
    };
    pre-commit-hooks.url = "github:cachix/pre-commit-hooks.nix";
  };

  outputs = {
    self,
    nixpkgs,
    crane,
    flake-utils,
    rust-overlay,
    advisory-db,
    pre-commit-hooks,
  }:
    {
      overlays.default = final: prev: {inherit (self.packages.${final.system}) ripsecrets;};
    }
    // flake-utils.lib.eachDefaultSystem (system: let
      craneLib = crane.lib.${system};
      src = craneLib.cleanCargoSource ./.;

      pkgs = import nixpkgs {
        inherit system;
        overlays = [(import rust-overlay)];
      };

      buildInputs =
        [pkgs.openssl]
        ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
          # Additional darwin specific inputs can be set here
          pkgs.gcc
          pkgs.darwin.apple_sdk.frameworks.Security
          pkgs.libiconv
        ];

      # Build *just* the cargo dependencies for caching.
      cargoArtifacts = craneLib.buildDepsOnly {inherit src buildInputs;};

      # Build ripsecrets itself, reusing the dependency artifacts from above.
      git-calver = craneLib.buildPackage {
        inherit cargoArtifacts src buildInputs;
        doCheck = false;
        scriptDeps = true;
        meta = with pkgs.lib; {
          description = "Calendar versioning utility";
          homepage = "https://github.com/takebayashi/git-calver";
          maintainers = [maintainers.lafrenierejm];
          mainProgram = "git-calver";
          license = licenses.asl20;
        };
      };

      pre-commit = pre-commit-hooks.lib."${system}".run;
    in rec {
      packages = {
        # `nix build .#git-calver`
        inherit git-calver;
        # `nix build`
        default = git-calver;
      };

      # `nix run`
      apps = rec {
        git-calver = flake-utils.lib.mkApp {drv = packages.git-calver;};
        default = git-calver;
      };

      # `nix flake check`
      checks =
        {
          audit = craneLib.cargoAudit {inherit src advisory-db;};

          clippy = craneLib.cargoClippy {
            inherit cargoArtifacts src buildInputs;
            cargoClippyExtraArgs = "--all-targets -- --deny warnings";
          };

          doc = craneLib.cargoDoc {inherit cargoArtifacts src;};

          fmt = craneLib.cargoFmt {inherit src;};

          nextest = craneLib.cargoNextest {
            inherit cargoArtifacts src buildInputs;
            partitions = 1;
            partitionType = "count";
          };

          pre-commit = pre-commit {
            src = ./.;
            hooks = {
              alejandra.enable = true;
              rustfmt.enable = true;
            };
          };
        }
        // pkgs.lib.optionalAttrs (system == "x86_64-linux") {
          # NB: cargo-tarpaulin only supports x86_64 systems
          # Check code coverage (note: this will not upload coverage anywhere)
          ripsecrets-coverage =
            craneLib.cargoTarpaulin {inherit cargoArtifacts src;};
        };

      # `nix develop`
      devShells.default = pkgs.mkShell {
        inherit (self.checks.${system}.pre-commit) shellHook;
        inherit buildInputs;
        inputsFrom = builtins.attrValues self.checks;
        nativeBuildInputs = with pkgs;
          lib.optionals (system == "x86_64-linux") [cargo-tarpaulin];
        packages = with pkgs; [cargo clippy nixfmt rustc rustfmt];
      };
    });
}
