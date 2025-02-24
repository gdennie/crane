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
          # wasm32-unknown-unknown is required for trunk.
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

        # Arguments to be used by both the client and the server
        # When building a workspace with crane, it's a good idea
        # to set "pname" and "version".
        commonArgs = {
          inherit src;
          strictDeps = true;

          buildInputs = [
            # Add additional build inputs here
          ] ++ lib.optionals pkgs.stdenv.isDarwin [
            # Additional darwin specific inputs can be set here
            pkgs.libiconv
          ];
        };

        # Native packages

        nativeArgs = commonArgs // {
          pname = "trunk-workspace-native";
        };

        # Build *just* the cargo dependencies, so we can reuse
        # all of that work (e.g. via cachix) when running in CI
        cargoArtifacts = craneLib.buildDepsOnly nativeArgs;

        # Simple JSON API that can be queried by the client
        myServer = craneLib.buildPackage (nativeArgs // {
          inherit cargoArtifacts;
          # The server needs to know where the client's dist dir is to
          # serve it, so we pass it as an environment variable at build time
          CLIENT_DIST = myClient;
        });

        # Wasm packages

        # it's not possible to build the server on the
        # wasm32 target, so we only build the client.
        wasmArgs = commonArgs // {
          pname = "trunk-workspace-wasm";
          cargoExtraArgs = "--package=client";
          CARGO_BUILD_TARGET = "wasm32-unknown-unknown";
        };

        cargoArtifactsWasm = craneLib.buildDepsOnly (wasmArgs // {
          doCheck = false;
        });

        # Build the frontend of the application.
        # This derivation is a directory you can put on a webserver.
        myClient = craneLib.buildTrunkPackage (wasmArgs // {
          pname = "trunk-workspace-client";
          cargoArtifacts = cargoArtifactsWasm;
          trunkIndexPath = "client/index.html";
          # The version of wasm-bindgen-cli here must match the one from Cargo.lock.
          wasm-bindgen-cli = pkgs.wasm-bindgen-cli.override {
            version = "0.2.93";
            hash = "sha256-DDdu5mM3gneraM85pAepBXWn3TMofarVR4NbjMdz3r0=";
            cargoHash = "sha256-birrg+XABBHHKJxfTKAMSlmTVYLmnmqMDfRnmG6g/YQ=";
          };
        });
      in
      {
        checks = {
          # Build the crate as part of `nix flake check` for convenience
          inherit myServer myClient;

          # Run clippy (and deny all warnings) on the crate source,
          # again, reusing the dependency artifacts from above.
          #
          # Note that this is done as a separate derivation so that
          # we can block the CI if there are issues here, but not
          # prevent downstream consumers from building our crate by itself.
          my-app-clippy = craneLib.cargoClippy (commonArgs // {
            inherit cargoArtifacts;
            cargoClippyExtraArgs = "--all-targets -- --deny warnings";
            # Here we don't care about serving the frontend
            CLIENT_DIST = "";
          });

          # Check formatting
          my-app-fmt = craneLib.cargoFmt commonArgs;
        };

        apps.default = flake-utils.lib.mkApp {
          name = "server";
          drv = myServer;
        };

        devShells.default = craneLib.devShell {
          # Inherit inputs from checks.
          checks = self.checks.${system};

          shellHook = ''
            export CLIENT_DIST=$PWD/client/dist;
          '';

          # Extra inputs can be added here; cargo and rustc are provided by default.
          packages = [
            pkgs.trunk
          ];
        };
      });
}
