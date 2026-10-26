{
  # yolo session images: one image per harness from the dotfiles (claude-code,
  # gemini-cli, codex, opencode, pi), each with the same login environment.
  # The datum backend runs the x86_64-linux images on Datum Compute, reached by
  # SSH over iroh; the docker backend runs the host's architecture
  # (x86_64-linux or aarch64-linux). Providers beyond each harness's native
  # ones come from ./providers via agent-providers. llm-agents and nixpkgs
  # follow the dotfiles' pins (`yolo sync-pins`, run by `yolo build`).
  #
  # Every tool ships as its full nix closure at the original /nix/store paths:
  # no patchelf (it can corrupt Bun executables), and wrapBuddy's hardcoded
  # loader and glibc paths resolve as built. One image per harness
  # (packages.<system>.<harness>; the Dockerfile's HARNESS build arg):
  #   yolo build claude --backend datum     # on the EC2 build box
  #   yolo build claude                     # local docker image
  description = "yolo session images, one per harness";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    # Same rev as the dotfiles (`yolo sync-pins`), but on llm-agents' own nixpkgs
    # rather than following ours as the dotfiles do: the harness versions are
    # the same, and only these builds are in cache.numtide.com.
    llm-agents.url = "github:numtide/llm-agents.nix";
    # The dotfiles: their zsh config goes into every image, and sync-pins reads
    # their flake.lock so llm-agents and nixpkgs match a laptop with them.
    dotfiles = { url = "github:drewr/dotfiles"; flake = false; };
  };

  outputs = { self, nixpkgs, llm-agents, dotfiles }:
  let
    # x86_64-linux for Datum Compute and Intel hosts; aarch64-linux for the
    # docker backend on Apple Silicon (podman machine / Docker Desktop VMs).
    systems = [ "x86_64-linux" "aarch64-linux" ];

    # The login user (SSH lands here, not root), whose HOME is the shared home.
    user = { name = "drewr"; uid = 1000; };

    perSystem = system: let
      pkgs = nixpkgs.legacyPackages.${system};
      # rtk, the token-saving command proxy yolo's claude hook runs: the upstream
      # release binary. nixpkgs' rtk is unfree (Apache-2.0 / BUSL-1.1), so it
      # isn't in cache.nixos.org and compiled from source in every image build.
      # x86_64 has a static musl build (in the release's checksums.txt);
      # aarch64 only a glibc build, which autoPatchelfHook points at nix's glibc.
      rtkSrc = {
        x86_64-linux = {
          asset = "rtk-x86_64-unknown-linux-musl.tar.gz";
          hash = "sha256-W5GcO8y3mbZ6YYZtDmF0EKT83xc+JhREDlneL6IANDY=";
        };
        aarch64-linux = {
          asset = "rtk-aarch64-unknown-linux-gnu.tar.gz";
          hash = "sha256-zWJ8QJGtkLXlrKg8pa9m7kuKqFN6c2Uz+pBUT0YfHCs=";
        };
      }.${system};
      rtk = pkgs.stdenv.mkDerivation {
        pname = "rtk";
        version = "1.0.1";
        src = pkgs.fetchurl {
          url = "https://github.com/rtk-ai/rtk/releases/download/v1.0.1/${rtkSrc.asset}";
          inherit (rtkSrc) hash;
        };
        sourceRoot = ".";
        nativeBuildInputs = [ pkgs.autoPatchelfHook ];
        buildInputs = [ pkgs.stdenv.cc.cc.lib ];
        installPhase = "install -Dm755 rtk $out/bin/rtk";
      };
      agents = llm-agents.packages.${system};
      # The same harnesses the dotfiles install (d/.config/home-manager/flake.nix),
      # from the same pinned llm-agents rev; opencode2 is also exposed as opencode.
      opencode = pkgs.symlinkJoin {
        name = "opencode";
        paths = [ agents.opencode2 ];
        postBuild = "ln -s ${agents.opencode2}/bin/opencode2 $out/bin/opencode";
      };
      # Image name -> harness package.
      harnesses = {
        claude = agents.claude-code;
        gemini = agents.gemini-cli;
        codex = agents.codex;
        inherit opencode;
        pi = agents.pi;
      };
      busybox = pkgs.pkgsStatic.busybox;
      base = [ rtk ] ++ (with pkgs; [ bashInteractive zsh gitMinimal openssh iputils ripgrep curl jq nix dropbear dumbpipe juicefs rsync ]);

      # Only the locale the dotfiles' zshenv asks for (LC_ALL=en_US.UTF-8).
      locales = pkgs.glibcLocales.override { allLocales = false; locales = [ "en_US.UTF-8/UTF-8" ]; };
      # The dotfiles' zsh config (zshrc, zshenv, zprofile, zsh.d).
      dotfilesZsh = pkgs.runCommand "dotfiles-zsh" { } ''
        mkdir -p $out
        cp ${dotfiles}/zshrc ${dotfiles}/zshenv ${dotfiles}/zprofile $out/
        cp -r ${dotfiles}/zsh.d $out/zsh.d
      '';

      # nix in the sandbox: a root nix-daemon (started by init) that the login
      # user talks to, builds as root (the image has no build users), no build
      # sandbox, flakes on, and nixpkgs pinned to the rev the images are built
      # from, so `nix shell nixpkgs#tool` mostly hits cache.nixos.org and needs
      # no global registry lookup. Store paths go to RAM (/nix is on the root
      # overlay) and last for the session.
      nixConf = pkgs.writeText "nix.conf" ''
        experimental-features = nix-command flakes
        build-users-group =
        sandbox = false
        trusted-users = root ${user.name}
        flake-registry =
        substituters = https://cache.nixos.org
        trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
      '';
      nixRegistry = pkgs.writeText "registry.json" (builtins.toJSON {
        version = 2;
        flakes = [{
          from = { type = "indirect"; id = "nixpkgs"; };
          to = { type = "github"; owner = "nixos"; repo = "nixpkgs"; rev = nixpkgs.rev; };
        }];
      });

      mkRootfs = name: harness: let
        # Linked into /bin ahead of busybox applets of the same name.
        tools = [ harness ] ++ base;
        closure = pkgs.closureInfo { rootPaths = tools ++ [ pkgs.cacert locales ]; };
      in pkgs.runCommand "agent-rootfs-${name}" { } ''
        R=$out
        mkdir -p $R/bin $R/etc/ssl/certs $R/root $R/tmp $R/run $R/nix/store $R/etc/agent

        for p in $(cat ${closure}/store-paths); do cp -a $p $R/nix/store/; done
        for t in ${pkgs.lib.concatStringsSep " " (map toString tools)}; do
          for b in $t/bin/*; do
            case "$(basename $b)" in .*) continue;; esac
            ln -sf $b $R/bin/$(basename $b)
          done
        done
        cp ${busybox}/bin/busybox $R/bin/busybox
        for a in $(${busybox}/bin/busybox --list); do
          [ -e $R/bin/$a ] || [ -L $R/bin/$a ] || ln -s /bin/busybox $R/bin/$a
        done
        cp ${./init.sh} $R/init
        cp ${./ws} $R/bin/ws
        cp ${./nix-zsh-env} $R/bin/nix-zsh-env   # for the dotfiles' zsh prompt
        cp ${./agent-providers} $R/bin/agent-providers
        ln -s agent-providers $R/bin/with-provider
        cp ${./providers} $R/etc/agent/providers
        # GitHub's published SSH host keys (gh api meta), so git over SSH needs no prompt.
        mkdir -p $R/etc/ssh
        cp ${./ssh_known_hosts} $R/etc/ssh/ssh_known_hosts
        echo ${name} > $R/etc/agent/harness
        # Store paths shipped in the image, for init to register with nix.
        cp ${closure}/registration $R/etc/agent/nix-registration
        mkdir -p $R/etc/nix $R/nix/var/nix
        cp ${nixConf} $R/etc/nix/nix.conf
        cp ${nixRegistry} $R/etc/nix/registry.json
        # Static parts of the login environment; init adds the session's.
        echo 'export LOCALE_ARCHIVE=${locales}/lib/locale/locale-archive' > $R/etc/agent/env.static
        cp -r ${dotfilesZsh} $R/etc/agent/zsh
        # Claude settings that seed a local (docker backend) home; see init.sh.
        cp -r ${./claude} $R/etc/agent/claude
        # zsh and bash login shells load the session environment (/etc/agent/env).
        echo '[ -r /etc/agent/env ] && . /etc/agent/env' > $R/etc/zshenv
        cp $R/etc/zshenv $R/etc/profile

        ln -s ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt $R/etc/ssl/certs/ca-certificates.crt
        printf 'root:x:0:0:root:/root:/bin/bash\n${user.name}:x:${toString user.uid}:${toString user.uid}:${user.name}:/home/agent:/bin/zsh\n' > $R/etc/passwd
        printf 'root:x:0:\n${user.name}:x:${toString user.uid}:\n' > $R/etc/group
        printf '/bin/zsh\n/bin/bash\n/bin/sh\n' > $R/etc/shells
        echo ${user.name} > $R/etc/agent/user
        echo 'hosts: files dns' > $R/etc/nsswitch.conf

        chmod -R u+w $R
        chmod 0555 $R/bin/busybox $R/init $R/bin/ws $R/bin/agent-providers $R/bin/nix-zsh-env
        chmod 0700 $R/root
        chmod 1777 $R/tmp
      '';
    in builtins.mapAttrs mkRootfs harnesses;
  in {
    packages = nixpkgs.lib.genAttrs systems perSystem;
    # For `yolo sync-pins`: the locked dotfiles source.
    lib.dotfiles = "${dotfiles}";
  };
}
