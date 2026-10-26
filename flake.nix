{
  # yolo, compiled. The script also runs as is (./yolo, via runghc), but pays
  # a few seconds of startup on every command; this builds it once.
  #
  #   nix run github:drewr/yolo -- ls
  #   nix profile install github:drewr/yolo
  #
  # nixpkgs and the Haskell packages match the script's shebang, so GHC and
  # the libraries come from cache.nixos.org; change both together.
  description = "yolo: coding agents in named, isolated sessions (docker/podman or Datum Compute)";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/02c087f3fe673c9e317f206a627cb6b910336dbe";

  outputs = { self, nixpkgs }:
  let
    systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
    forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

    mkYolo = pkgs: let
      ghc = pkgs.haskellPackages.ghcWithPackages (p: with p; [
        aeson crypton memory base16-bytestring base64-bytestring network
      ]);
      # The shebang's `-p` tools; the rest (datumctl, docker/podman, ssh,
      # aws, nix) are the host's own, from PATH.
      tools = builtins.filter (p: pkgs.lib.meta.availableOn pkgs.stdenv.hostPlatform p)
        (with pkgs; [ dumbpipe socat buildkit ]);
    in pkgs.stdenv.mkDerivation {
      pname = "yolo";
      version = self.shortRev or self.dirtyShortRev or "dev";
      src = pkgs.lib.fileset.toSource {
        root = ./.;
        fileset = ./yolo;
      };
      nativeBuildInputs = [ ghc pkgs.makeWrapper ];
      # Compiled into `yolo version`: the commit (-dirty for uncommitted
      # changes) and its date.
      YOLO_BUILD_REV = self.shortRev or self.dirtyShortRev or "unknown";
      YOLO_BUILD_DATE = let d = self.lastModifiedDate or ""; in
        if d == "" then "unknown"
        else "${builtins.substring 0 4 d}-${builtins.substring 4 2 d}-${builtins.substring 6 2 d}";
      buildPhase = ''
        runHook preBuild
        ghc -O -threaded -rtsopts -x hs yolo -outputdir build -o yolo-bin
        runHook postBuild
      '';
      # YOLO_ROOT: the repository the binary was built from (images,
      # Dockerfile, image flake), read-only; set it to a checkout to use
      # newer pins or to run `yolo build --backend datum`.
      installPhase = ''
        runHook preInstall
        install -Dm755 yolo-bin $out/bin/yolo
        wrapProgram $out/bin/yolo \
          --prefix PATH : ${pkgs.lib.makeBinPath tools} \
          --set-default YOLO_ROOT ${self}
        runHook postInstall
      '';
      meta.mainProgram = "yolo";
    };
  in {
    packages = forAll (pkgs: rec {
      yolo = mkYolo pkgs;
      default = yolo;
    });
    apps = forAll (pkgs: {
      default = { type = "app"; program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.yolo}/bin/yolo"; };
    });
  };
}
