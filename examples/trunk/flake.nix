{
  description = "Build a cargo project";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    # The version of wasm-bindgen-cli needs to match the version in Cargo.lock
    # Update this to include the version you need
    nixpkgs-for-wasm-bindgen.url = "github:NixOS/nixpkgs/4e6868b1aa3766ab1de169922bb3826143941973";

    crane.url = "github:ipetkov/crane";

    flake-utils.url = "github:numtide/flake-utils";

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, crane, flake-utils, rust-overlay, nixpkgs-for-wasm-bindgen, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ (import rust-overlay) ];
        };

        inherit (pkgs) lib;

        rustToolchainFor = p: p.rust-bin.stable.latest.default.override {
          # Set the build targets supported by the toolchain,
          # wasm32-unknown-unknown is required for trunk
          targets = [ "wasm32-unknown-unknown" ];
        };
        craneLib = ((crane.mkLib pkgs).overrideToolchain rustToolchainFor).overrideScope (_final: _prev: {
          # The version of wasm-bindgen-cli needs to match the version in Cargo.lock. You
          # can unpin this if your nixpkgs commit contains the appropriate wasm-bindgen-cli version
          inherit (import nixpkgs-for-wasm-bindgen { inherit system; }) wasm-bindgen-cli;
        });

        # When filtering sources, we want to allow assets other than .rs files
        unfilteredRoot = ./.; # The original, unfiltered source
        src = lib.fileset.toSource {
          root = unfilteredRoot;
          fileset = lib.fileset.unions [
            # Default files from crane (Rust and cargo files)
            (craneLib.fileset.commonCargoSources unfilteredRoot)
            (lib.fileset.fileFilter
              (file: lib.any file.hasExt [ "html" "scss" ])
              unfilteredRoot
            )
            # Example of a folder for images, icons, etc
            (lib.fileset.maybeMissing ./assets)
          ];
        };

        # Common arguments can be set here to avoid repeating them later
        commonArgs = {
          inherit src;
          strictDeps = true;
          # We must force the target, otherwise cargo will attempt to use your native target
          CARGO_BUILD_TARGET = "wasm32-unknown-unknown";

          buildInputs = [
            # Add additional build inputs here
          ] ++ lib.optionals pkgs.stdenv.isDarwin [
            # Additional darwin specific inputs can be set here
            pkgs.libiconv
          ];
        };

        # Build *just* the cargo dependencies, so we can reuse
        # all of that work (e.g. via cachix) when running in CI
        cargoArtifacts = craneLib.buildDepsOnly (commonArgs // {
          # You cannot run cargo test on a wasm build
          doCheck = false;
        });

        # Build the actual crate itself, reusing the dependency
        # artifacts from above.
        # This derivation is a directory you can put on a webserver.
        my-app = craneLib.buildTrunkPackage (commonArgs // {
          inherit cargoArtifacts;
          # The version of wasm-bindgen-cli here must match the one from Cargo.lock.
          wasm-bindgen-cli = pkgs.wasm-bindgen-cli.override {
            version = "0.2.93";
            hash = "sha256-DDdu5mM3gneraM85pAepBXWn3TMofarVR4NbjMdz3r0=";
            cargoHash = "sha256-birrg+XABBHHKJxfTKAMSlmTVYLmnmqMDfRnmG6g/YQ=";
          };
        });

        # Quick example on how to serve the app,
        # This is just an example, not useful for production environments
        serve-app = pkgs.writeShellScriptBin "serve-app" ''
          ${pkgs.python3Minimal}/bin/python3 -m http.server --directory ${my-app} 8000
        '';
      in
      {
        checks = {
          # Build the crate as part of `nix flake check` for convenience
          inherit my-app;

          # Run clippy (and deny all warnings) on the crate source,
          # again, reusing the dependency artifacts from above.
          #
          # Note that this is done as a separate derivation so that
          # we can block the CI if there are issues here, but not
          # prevent downstream consumers from building our crate by itself.
          my-app-clippy = craneLib.cargoClippy (commonArgs // {
            inherit cargoArtifacts;
            cargoClippyExtraArgs = "--all-targets -- --deny warnings";
          });

          # Check formatting
          my-app-fmt = craneLib.cargoFmt {
            inherit src;
          };
        };

        packages.default = my-app;

        apps.default = flake-utils.lib.mkApp {
          drv = serve-app;
        };

        devShells.default = craneLib.devShell {
          # Inherit inputs from checks.
          checks = self.checks.${system};

          # Additional dev-shell environment variables can be set directly
          # MY_CUSTOM_DEVELOPMENT_VAR = "something else";

          # Extra inputs can be added here; cargo and rustc are provided by default.
          packages = [
            pkgs.trunk
          ];
        };
      });
}
