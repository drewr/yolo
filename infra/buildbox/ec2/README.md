# EC2 build box

Builds Datum Compute images until Datum offers instance types large enough to
build on-platform (datum-cloud/compute#492). Sizing and cost:
`docs/datum-build-box-ec2.md`.

- **Box:** NixOS on `t3a.large`, `us-east-2`, profile `datum-sandbox-admin`. The
  whole config is `configuration.nix`, pinned by `flake.lock`. At first boot the
  box applies the config itself from `github:drewr/yolo/<rev>?dir=infra/buildbox/ec2`.
- **Access:** no inbound ports. BuildKit listens on `127.0.0.1:1234` and is reached
  only through a dumbpipe (iroh) ticket. Shell access goes through SSM Session Manager.
- **Idle stop:** after 30 minutes with no client and no build, the box powers
  itself off (stopped, not terminated). `yolo build` starts it again, as does
  `yolo infra buildbox start`.
- **Reproducibility:** the image's inputs are pinned by the context's
  `flake.lock` and the base image digest in `Dockerfile.datum`. Building the same
  commit twice gives the same image digest.

## Once

```sh
aws sso login --sso-session Datum
git push                                       # the box fetches its config from GitHub
yolo infra buildbox launch           # pinned to HEAD (must be pushed); from a checkout
yolo infra buildbox ticket           # after ~5 min; it is stable
```

The ticket works like a password for BuildKit. Store it as a secret.

## Each build

`yolo build HARNESS --backend datum [--class general-purpose]` builds the yolo
images here. It reads the ticket from the box (and saves it) the first time,
and starts the box if it has stopped itself, so usually you only need a
current AWS login (`aws sso login --profile datum-sandbox-admin`). For anything else, hold a tunnel to the box's BuildKit open and
point datumctl (or buildctl) at it:

```sh
yolo infra buildbox tunnel           # 127.0.0.1:12340, until ctrl-c
datumctl compute build --push --buildkit-host tcp://127.0.0.1:12340 -o ghcr.io/drewr/sp3-node:dev sp3
```

The nix build and the BuildKit solve run on the box. datumctl then packages the
image and pushes it from the client, so the client transfers the image (~300 MB
for sp3) but does no heavy compute.

## Updating the box

Change `configuration.nix`, push, and either `yolo infra buildbox terminate`
then `yolo infra buildbox launch`, or run this in an SSM session:
`nixos-rebuild switch --flake 'github:drewr/yolo/<rev>?dir=infra/buildbox/ec2#buildbox'`.
A new instance gets a new ticket, because the iroh key lives on the instance's volume.
