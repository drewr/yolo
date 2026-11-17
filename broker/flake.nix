{
  # yolo-broker: a credential broker for sandboxed coding agents. Runs next to
  # superfly/tokenizer on a persistent host; sandboxes reach it over iroh.
  # Self-contained: nothing here refers to files outside this directory.
  description = "yolo-broker and yolo-broker-proxy";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/02c087f3fe673c9e317f206a627cb6b910336dbe";

  outputs = { self, nixpkgs }:
  let
    systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
    forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

    # superfly/tokenizer, used unmodified as a separate process.
    mkTokenizer = pkgs: pkgs.buildGoModule {
      pname = "tokenizer";
      version = "0.0.1-0f51c9d";
      src = pkgs.fetchFromGitHub {
        owner = "superfly";
        repo = "tokenizer";
        rev = "0f51c9d780d0edea243574c12e7ba43a15894595";
        hash = "sha256-DAWuQnpFplNxB7G+HIUiMCfYmfU59pwbVi6KTR4ZxSE=";
      };
      vendorHash = "sha256-L52HJC/h65I/QjaaGdwupHKJca+61tudQy5CINQuwPU=";
      subPackages = [ "cmd/tokenizer" ];
      doCheck = false;
      meta.mainProgram = "tokenizer";
    };

    # Tests only: the same library behind a main that allows loopback
    # upstreams (see nix/tokenizer-test.go).
    mkTokenizerTest = pkgs: (mkTokenizer pkgs).overrideAttrs (old: {
      pname = "tokenizer-test";
      subPackages = [ "cmd/tokenizer-test" ];
      postPatch = ''
        mkdir -p cmd/tokenizer-test
        cp ${./nix/tokenizer-test.go} cmd/tokenizer-test/main.go
      '';
      meta.mainProgram = "tokenizer-test";
    });

    # Both binaries (yolo-broker, yolo-broker-proxy). The check phase runs the
    # whole suite, integration tests included, against the tokenizer packages.
    mkBroker = pkgs: pkgs.rustPlatform.buildRustPackage {
      pname = "yolo-broker";
      version = "0.1.0";
      src = pkgs.lib.cleanSource ./.;
      cargoLock.lockFile = ./Cargo.lock;
      TOKENIZER_BIN = "${mkTokenizer pkgs}/bin/tokenizer";
      TOKENIZER_TEST_BIN = "${mkTokenizerTest pkgs}/bin/tokenizer-test";
    };
  in {
    packages = forAll (pkgs: {
      default = mkBroker pkgs;
      yolo-broker = mkBroker pkgs;
      tokenizer = mkTokenizer pkgs;
      tokenizer-test = mkTokenizerTest pkgs;
    });

    devShells = forAll (pkgs: {
      default = pkgs.mkShell {
        packages = [ pkgs.cargo pkgs.rustc pkgs.clippy pkgs.rustfmt ];
        # `cargo test` runs the integration tests for real in this shell.
        TOKENIZER_BIN = "${mkTokenizer pkgs}/bin/tokenizer";
        TOKENIZER_TEST_BIN = "${mkTokenizerTest pkgs}/bin/tokenizer-test";
      };
    });
  };
}
