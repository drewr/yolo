{
  # yolo session images: one image per harness (claude-code, gemini-cli, codex,
  # opencode, pi), each with the same login environment.
  # The datum backend runs the x86_64-linux images on Datum Compute, reached by
  # SSH over iroh; the docker backend runs the host's architecture
  # (x86_64-linux or aarch64-linux). Providers beyond each harness's native
  # ones come from ./providers via agent-providers. With YOLO_DOTFILES set,
  # llm-agents and nixpkgs follow the dotfiles' pins (`yolo sync-pins`, run by
  # `yolo build`).
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
    # Same rev as the dotfiles when there are any (`yolo sync-pins`), but on
    # llm-agents' own nixpkgs rather than following ours as the dotfiles do: the
    # harness versions are the same, and only these builds are in
    # cache.numtide.com.
    llm-agents.url = "github:numtide/llm-agents.nix";
    # Your dotfiles: their zsh config goes into every image, and sync-pins reads
    # their flake.lock so llm-agents and nixpkgs match a laptop with them. The
    # default is this repository, which has no zsh config, so the images get
    # none; yolo overrides it with $YOLO_DOTFILES (--override-input dotfiles
    # github:OWNER/dotfiles). Not a relative path: Lix can't fetch those.
    dotfiles = { url = "github:drewr/yolo"; flake = false; };
    # The yolo CLI, for the jump image, which launches sandboxes itself. Pinned
    # in flake.lock; bump it (`nix flake update yolo`) when the CLI changes.
    yolo.url = "github:drewr/yolo/feature-jump-box";
    # The credential broker (yolo-broker, yolo-broker-proxy) and the tokenizer
    # it runs beside. Not a relative path: Lix can't fetch those. Follows our
    # nixpkgs so the images carry one glibc.
    broker = {
      url = "github:drewr/yolo/feature-jump-box?dir=broker";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, llm-agents, dotfiles, yolo, broker }:
  let
    # x86_64-linux for Datum Compute and Intel hosts; aarch64-linux for the
    # docker backend on Apple Silicon (podman machine / Docker Desktop VMs).
    systems = [ "x86_64-linux" "aarch64-linux" ];

    # The login user (SSH lands here, not root), whose HOME is the shared home.
    # A placeholder: init renames it at boot to $YOLO_USER (yolo passes it in).
    user = { name = "agent"; uid = 1000; };

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
      # datumctl, for the jump image: the upstream release binary (a static Go
      # executable, so no patchelf). Not in nixpkgs.
      datumctlSrc = {
        x86_64-linux = {
          asset = "datumctl_Linux_x86_64.tar.gz";
          hash = "sha256-gUHR7pi8Cj8X6StYCG6CurI7jXkMPsUqaO8GG6mhmYI=";
        };
        aarch64-linux = {
          asset = "datumctl_Linux_arm64.tar.gz";
          hash = "sha256-EmwpTsWxcQvEwZxorZxpwjx+cxRA2TNG4RWpSqjMxtE=";
        };
      }.${system};
      datumctl = pkgs.stdenv.mkDerivation {
        pname = "datumctl";
        version = "0.24.0";
        src = pkgs.fetchurl {
          url = "https://github.com/datum-cloud/datumctl/releases/download/v0.24.0/${datumctlSrc.asset}";
          inherit (datumctlSrc) hash;
        };
        sourceRoot = ".";
        installPhase = "install -Dm755 datumctl $out/bin/datumctl";
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
      # Every harness image: the login tools, and yolo-broker-proxy, which
      # init starts for a sandbox with a broker (yolo-broker rides along).
      base = [ rtk broker.packages.${system}.yolo-broker ] ++ (with pkgs; [ bashInteractive zsh gitMinimal openssh iputils ripgrep curl jq nix dropbear dumbpipe juicefs rsync tmux ]);
      # The jump box: no agent harness, nix, juicefs or rtk. It holds keys in one
      # persistent ssh-agent that `jump setup` starts; a client logs in without
      # forwarding its agent, and logins, tmux and held connections all use that
      # agent. It reads its Config over HTTPS through `yolo cfg`, and runs yolo
      # and datumctl to launch Datum sandboxes. ssh-keyscan comes with openssh;
      # su, mount, tar and gzip are busybox applets, linked into /bin by mkRootfs.
      # The jump image's helper (`jump setup`, `jump login`), in that image only.
      jumpScript = pkgs.runCommand "jump" { } ''
        mkdir -p $out/bin
        cp ${./jump} $out/bin/jump
        chmod 0555 $out/bin/jump
      '';
      # The jump image also runs the broker and its tokenizer (on 127.0.0.1:8080).
      jumpTools = [ yolo.packages.${system}.yolo datumctl jumpScript broker.packages.${system}.yolo-broker broker.packages.${system}.tokenizer ]
        ++ (with pkgs; [ bashInteractive zsh gitMinimal openssh iputils curl jq dropbear dumbpipe tmux ]);

      # Only the locale the dotfiles' zshenv asks for (LC_ALL=en_US.UTF-8).
      locales = pkgs.glibcLocales.override { allLocales = false; locales = [ "en_US.UTF-8/UTF-8" ]; };
      # The dotfiles' zsh config (zshrc, zshenv, zprofile, zsh.d), when there
      # are dotfiles with one.
      hasZsh = builtins.all (f: builtins.pathExists "${dotfiles}/${f}") [ "zshrc" "zshenv" "zprofile" "zsh.d" ];
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
        trusted-users = root @${user.name}
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

      mkRootfs = name: tools: let
        # Linked into /bin ahead of busybox applets of the same name.
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
        ${pkgs.lib.optionalString hasZsh "cp -r ${dotfilesZsh} $R/etc/agent/zsh"}
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
    in builtins.mapAttrs (name: harness: mkRootfs name ([ harness ] ++ base)) harnesses
       // { jump = mkRootfs "jump" jumpTools; };
  in {
    packages = nixpkgs.lib.genAttrs systems perSystem;
    # For `yolo sync-pins`: the locked dotfiles source.
    lib.dotfiles = "${dotfiles}";
  };
}
