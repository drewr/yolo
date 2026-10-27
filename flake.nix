{
  # yolo, in Zig. Built with zigutils' zig-dev pin, so the compiler is bumped in
  # one place (zigutils/flake.nix).
  #
  #   nix run github:drewr/yolo -- ls
  #   nix profile install github:drewr/yolo
  #
  # Development: nix develop, then `zig build run -- ARGS` (YOLO_ROOT points
  # at the checkout while developing).
  description = "yolo: coding agents in named, isolated sessions (docker/podman or Datum Compute)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/02c087f3fe673c9e317f206a627cb6b910336dbe";
    zigutils = {
      url = "github:drewr/zigutils";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, zigutils }:
  let
    systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
    forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system} system);

    mkYolo = pkgs: system: let
      zig = zigutils.packages.${system}.zig-dev;
      # dumbpipe, socat and buildctl come from nixpkgs on PATH; datumctl,
      # docker/podman/colima, ssh, ssh-keygen, ssh-add, aws, git and nix are
      # the host's own.
      tools = builtins.filter (p: pkgs.lib.meta.availableOn pkgs.stdenv.hostPlatform p)
        (with pkgs; [ dumbpipe socat buildkit ]);
      # Compiled into `yolo version`: the commit (-dirty for uncommitted
      # changes) and its date.
      rev = self.shortRev or self.dirtyShortRev or "unknown";
      date = let d = self.lastModifiedDate or ""; in
        if d == "" then "unknown"
        else "${builtins.substring 0 4 d}-${builtins.substring 4 2 d}-${builtins.substring 6 2 d}";
    in pkgs.stdenv.mkDerivation {
      pname = "yolo";
      version = self.shortRev or self.dirtyShortRev or "dev";
      src = pkgs.lib.fileset.toSource {
        root = ./.;
        fileset = pkgs.lib.fileset.unions [
          ./build.zig
          ./src
          ./tests
        ];
      };
      nativeBuildInputs = [ zig pkgs.makeWrapper ];
      # zig needs a writable HOME for its cache; the store copy is read-only.
      buildPhase = ''
        runHook preBuild
        export HOME=$TMPDIR
        zig build -Doptimize=ReleaseSafe -Dversion=${rev} -Ddate=${date} --prefix $out
        runHook postBuild
      '';
      dontInstall = true;
      nativeCheckInputs = [ zig ];
      doCheck = true;
      checkPhase = ''
        runHook preCheck
        export HOME=$TMPDIR
        zig build test -Dversion=${rev} -Ddate=${date}
        runHook postCheck
      '';
      # YOLO_ROOT: the repository the binary was built from (images,
      # Dockerfile, image flake), read-only; set it to a checkout to use newer
      # pins or to run `yolo build --backend datum`.
      postFixup = ''
        wrapProgram $out/bin/yolo \
          --prefix PATH : ${pkgs.lib.makeBinPath tools} \
          --set-default YOLO_ROOT ${self}
      '';
      meta.mainProgram = "yolo";
    };
  in {
    packages = forAll (pkgs: system: rec {
      yolo = mkYolo pkgs system;
      default = yolo;
    });
    apps = forAll (pkgs: system: {
      default = {
        type = "app";
        program = "${self.packages.${system}.yolo}/bin/yolo";
      };
    });
    devShells = forAll (pkgs: system: {
      default = pkgs.mkShell {
        packages = [ zigutils.packages.${system}.zig-dev pkgs.zls ];
      };
    });
  };
}
